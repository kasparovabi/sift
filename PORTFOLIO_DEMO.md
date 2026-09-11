# Sift — isolated English browser demo

The existing English browser app uses the real SQLite index, search and session reader, seeded with the repository's synthetic demo transcripts. Run `python3 scripts/demo-data.py .portfolio-data/projects` once, then `node web/portfolio-demo.mjs`.

Both transcript roots and the support directory are isolated. Every non-GET action is blocked, including terminal launch, file reveal and retention settings. The demo does not read the real Claude/Codex libraries. This evidence covers the browser version, not the native Mac or Windows clients.
