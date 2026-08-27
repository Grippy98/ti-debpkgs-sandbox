# Publication requests

Publication is always explicit. Commit a request matching
`schemas/publication-request.schema.json`, review it in a pull request, merge it
to `main`, and manually dispatch the publisher with that exact path.

Request IDs are one-shot. A successful archive snapshot records the complete
request and rejects reuse of the same ID.
