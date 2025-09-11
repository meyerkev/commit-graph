# commit-graph
Make a bunch of commits so my GitHub graph looks good.

## Usage

Local backfill (from 2023-01-01 to today):

```
# Uses your git config user.name/user.email by default
./scripts/graph-backfill.sh --start 2023-01-01

# Or specify explicitly
./scripts/graph-backfill.sh --start 2023-01-01 \
  --author-name "Your Name" --author-email you@example.com
```

Last week (dry run):

```
./scripts/graph-backfill.sh \
  --start "$(date -u -d '7 days ago' +%F)" \
  --end   "$(date -u -d 'yesterday' +%F)" \
  --dry-run
```

Flags: `--min 15 --max 100` control daily range. Commits append to `.graph-seed`.

## GitHub Action

- Add repo variables: `GRAPH_AUTHOR_NAME`, `GRAPH_AUTHOR_EMAIL` (must match a verified email).
- Add secret: `GRAPH_PAT` with `public_repo` (or `repo` for private repos).
- Action runs nightly and backfills the last 7 days as needed.
