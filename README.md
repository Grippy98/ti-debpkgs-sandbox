# TI Debian package publication sandbox

This repository exercises the publication boundary between
[`Grippy98/ti-debian-repos`](https://github.com/Grippy98/ti-debian-repos)
and a signed APT repository without granting the build workflow access to the
archive signing key.

The sandbox is intentionally small:

- `Grippy98/ti-debian-repos` builds one deterministic candidate bundle and
  creates GitHub build-provenance attestation for that exact file.
- This repository verifies the opaque bundle's provenance before opening it,
  validates its Debian metadata, and publishes an explicitly reviewed request.
- `main` contains policy, validation code, workflows, and publication requests.
- Generated archive state is stored as versioned GitHub Release snapshots, not
  committed to Git history.
- GitHub Pages receives only the public `dists/`, `pool/`, keyring, APT source
  example, and signed snapshot head from a fully validated snapshot.

The archive and producer repositories therefore have different credentials.
The producer can create candidates but cannot sign or publish the APT archive;
the publisher can read candidates but cannot modify the producer repository.

## Attested two-repository flow

The producer workflow currently trusted by `policy/archive.json` is
`Grippy98/ti-debian-repos/.github/workflows/cc33conf-candidate.yml` on
`refs/heads/codex/cc33conf-candidate`.

1. The producer builds the complete source and ARM64 binary closure on a
   GitHub-hosted ARM64 runner.
2. It creates one deterministic `candidate-*.tar.gz`. File order, ownership,
   modes and timestamps are normalized, and `gzip -n` removes time-dependent
   headers. The archive contains `manifest.json`, `SHA256SUMS`, and `payload/`.
3. A separate clean job downloads exactly that one file and uses
   `actions/attest` to attest its digest. Only then is it uploaded as the final
   Actions artifact. Its run attempt, artifact ID and digest, bundle name and
   digest, producer commit, package version, and attestation URL are printed in
   the workflow summary.
4. An `include` request commits those exact values under `requests/` in this
   repository. The publisher fetches the named run attempt and artifact using a
   read-only token and verifies both the Actions transport digest and candidate
   bundle digest.
5. Before extracting the tar archive, `gh attestation verify` must match all of
   the following:
   - repository `Grippy98/ti-debian-repos`;
   - exact signer workflow from `policy/archive.json`;
   - exact allow-listed source ref;
   - requested producer commit as both source and signer digest;
   - requested workflow run ID and attempt; and
   - a GitHub-hosted, not self-hosted, runner.
6. Only after provenance succeeds does the publisher safely extract the bundle
   and validate its closed file set, hashes, sizes, manifest, `.changes`,
   `.buildinfo`, `.dsc`, source tarballs, `.deb` metadata, suite, component,
   architecture, upstream commit, and Debian version ordering.
7. The secretless planning job reconstructs the current signed archive and
   writes a reviewable plan. The protected signing job repeats the retrieval and
   verification after approval, imports the disposable sandbox key into an
   isolated `GNUPGHOME`, and applies the request to a copy of archive state.
8. The signed state and audit receipt become a draft snapshot release. Pages is
   deployed from the same state, the deployed `snapshot.json` must exactly match
   the release asset, and only then is the release made non-draft. A final live
   APT smoke test verifies the Pages archive.

The successful archive snapshot retains the request, candidate manifest,
Debian `.changes` and `.buildinfo`, and the JSON result of attestation
verification under `audit/requests/<request-id>/`. GitHub remains the authority
for the Sigstore attestation itself. For independent offline re-verification,
the producer/publisher should additionally retain the bundle returned by
`gh attestation download` as a checksummed snapshot asset; that extra offline
bundle retention is not implemented yet.

## Publication requests

Every operation is an explicit JSON file under `requests/`:

- `include` promotes one attested candidate and also handles later, strictly
  newer versions.
- `remove-source` removes one exact source name and version.

Deleting packaging from the producer repository never implicitly removes a
published package. Request IDs are one-shot and are recorded in the signed
archive state. See `requests/examples/` for the request format.

## Required GitHub configuration

These settings are part of the security model. The workflows deliberately fail
closed if invoked from a different repository, ref, workflow, commit, event, or
runner architecture.

### Protect trusted branches

In `Grippy98/ti-debian-repos`, protect the currently trusted
`codex/cc33conf-candidate` branch. Disable force pushes and deletion, require
changes through pull requests, and require its build/test checks. When the
producer is moved to `master`, update `policy/archive.json` and protect
`master` before trusting that ref.

In `Grippy98/ti-debpkgs-sandbox`, protect `main`. Disable force pushes and
deletion, require pull requests, and require `Validate sandbox publisher` to
pass. Publication requests and any changes to workflows, policy, public keys,
or validation code must be reviewed on `main` before dispatch.

The repository Actions setting must permit the job-scoped `GITHUB_TOKEN`
permissions declared by the workflows. The workflows start from
`permissions: {}` and grant write access only to the release or Pages job that
needs it.

### Configure `sandbox-publish`

Create an environment named exactly `sandbox-publish` in this repository:

- allow deployments from `main` only;
- add a required reviewer so the secretless plan is inspected before signing;
- store the private disposable key as the environment secret
  `SANDBOX_APT_SIGNING_KEY_B64`.

The decoded private key must match fingerprint
`2F7DEBAA4171752E3B230AE4F51788F503B519B5` in `policy/archive.json` and the
committed public key. It is a test-only identity and must never be reused for a
TI production archive. A single-user sandbox may allow the initiator to approve
their own deployment; production should prevent self-review and require a
second person.

### Configure candidate read access

Create a fine-grained personal access token selected for only
`Grippy98/ti-debian-repos`, with:

- Actions: read-only;
- Attestations: read-only;
- no write permission.

Store it in this repository as the repository secret `CANDIDATE_READ_TOKEN`.
It is intentionally a repository secret, rather than a `sandbox-publish`
environment secret, because the pre-approval planning job must retrieve and
verify the candidate. Its read-only, single-repository scope limits that
exposure. Metadata read access supplied by GitHub is sufficient for repository
identity checks.

### Configure Pages

In **Settings > Pages**, select **GitHub Actions** as the publishing source.
Configure the `github-pages` environment to allow deployments from `main` only.
The deploy job alone receives `pages: write` and `id-token: write`; it never
receives the APT private key or producer token.

The expected sandbox URL is
`https://grippy98.github.io/ti-debpkgs-sandbox/`.

### Enable immutable releases

Enable immutable releases for this repository before the first publication.
Each non-draft `archive-snapshot-<run>-<attempt>` release is permanent archive
state. Do not replace assets, move its tag, or delete old snapshots. Published
releases are the state lineage from which the next request is built; Pages is
the public deployment of the current head.

## First publication

`workflow_dispatch` workflows are discoverable and runnable only after the
workflow file exists on the repository's default branch. Because this
repository starts empty, first push and establish `main`, configure the settings
above, and merge the initial files before trying to use the Actions **Run
workflow** button. Always select `main`: both publisher and recovery workflows
explicitly reject dispatches whose workflow ref is not `refs/heads/main`.

For the first real `include` request, no signed snapshot exists. Dispatch
`Publish signed sandbox archive` with the committed request path and set
`initialize_empty_archive` to `true`. This authorization is accepted only when
there is no non-draft snapshot release and the Pages `snapshot.json` endpoint
is absent. Leave the option `false` for every later publication. A mismatch
between Releases and Pages blocks initialization instead of silently replacing
an existing archive.

## Draft release and recovery behavior

The normal publisher deliberately creates the snapshot release as a draft
before deploying Pages. It publishes the draft only after the live Pages
`snapshot.json` exactly matches the signed snapshot metadata.

If deployment or finalization fails after the draft was created, do not delete
the draft and do not start a new publication. First rerun the failed jobs. If
that is not sufficient, manually dispatch `Recover Pages from signed snapshot`
from `main` with the exact newest `archive-snapshot-<run>-<attempt>` tag. The
recovery workflow:

1. accepts only the newest snapshot tag, including a draft;
2. verifies the exact release asset set, GitHub asset digests, `SHA256SUMS`,
   signed snapshot metadata, archive contents, and APT signatures;
3. waits at the same `sandbox-publish` approval gate;
4. redeploys Pages from that verified snapshot; and
5. publishes the draft only after Pages matches it, then repeats the live APT
   smoke test.

This is reconciliation of an interrupted publication, not arbitrary rollback.
Older snapshots cannot be silently promoted over newer archive state.

## Local verification

The integration test runs in Debian Trixie and exercises signed archive
creation, update, exact removal, repository integrity checks, request and
candidate rejection cases, safe extraction, snapshot recovery, and an isolated
APT client:

```sh
docker run --rm --platform linux/arm64 \
  -v "$PWD:/workspace" -w /workspace debian:trixie \
  ./tests/run-in-container.sh
```

Local and pull-request tests are necessary but do not prove the GitHub trust
boundary. Live end-to-end validation is still required after both branches are
pushed and the settings above are configured:

1. run the producer workflow on GitHub's ARM64 runner;
2. confirm a single deterministic bundle, Actions artifact digest, and GitHub
   attestation are present;
3. commit a request using the workflow's exact summary values;
4. inspect the publisher plan, approve `sandbox-publish`, and confirm the
   snapshot release becomes non-draft only after Pages deployment;
5. verify `apt-get update` and package download against the public Pages URL;
6. publish a newer version and exercise exact removal; and
7. deliberately test the newest-draft recovery path.

Until that live sequence passes, this repository is an implementation ready
for integration testing, not a proven publication service.
