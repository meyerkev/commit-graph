# commit-graph
Make a bunch of commits so my GitHub graph looks good to HR so that I can be allowed to talk to the person reading this.

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
By default, batching is enabled and checkpoints occur every 1000 commits (no pushing unless explicitly enabled).

Batch push/rotate (optional):

```
# Every ~1000 commits, push and rotate to a new branch
./scripts/graph-backfill.sh --start 2023-01-01 \
  --batch-size 1000 --enable-push --remote origin --push-branch main --rotate \
  --branch-prefix graph-batch

# Dry run (no commits, no pushes):
./scripts/graph-backfill.sh --start 2023-01-01 \
  --batch-size 1000 --remote origin --push-branch main --rotate --dry-run
```

Notes:
- Pushes are disabled by default; add `--enable-push` to actually push.
- `--rotate` creates and checks out a new branch at each checkpoint; pushes continue updating `--push-branch` (e.g., `main`).
- Omit `--push-branch` to push to the current branch name.
- Default `--batch-size` is `1000`. Disable batching with `--batch-size 0` if undesired.
- The script performs a final push at the end if the last batch is under the threshold (no rotation on the final push).

Push retry controls:

```
--push-retries 7 --push-backoff 3   # up to 7 attempts with exponential backoff starting at 3s
```

Retry behavior details:
- On a push failure, the script fetches `origin/<branch>` and attempts a merge using `-X ours` to prefer local changes (safe for append-only `.graph-seed`).
- After merge (or if fetch/merge fails), it retries with exponential backoff until `--push-retries` is exhausted.
- The workflow still contains a final safety push; with `--enable-push`, that step is usually a no-op fast-forward.

Defaults:
- Script retries: 100 attempts, starting backoff 2s (doubles each retry).
- Workflow safety push: up to 100 attempts with incremental backoff.

## GitHub Action

- Add repo variables: `GRAPH_AUTHOR_NAME`, `GRAPH_AUTHOR_EMAIL` (must match a verified email).
- Add secret: `GRAPH_PAT` with `public_repo` (or `repo` for private repos).
- Action runs nightly and backfills the last 7 days as needed.

## Historical Backfill (2010 → today)

Prefer triggering GitHub Actions per-month instead of generating millions of local commits.

- Dry run (prints planned dispatches):

```
./scripts/trigger-monthly-backfill.sh \
  --from-year 2010 --ref main --dry-run
```

- Real dispatches (requires `GITHUB_TOKEN` with `repo` scope; derives `--repo` from `origin` if present):

```
GITHUB_TOKEN=ghp_yourtoken ./scripts/trigger-monthly-backfill.sh \
  --from-year 2010 --ref main
```

- Optional density overrides for the workflow’s daily commits:

```
GITHUB_TOKEN=... ./scripts/trigger-monthly-backfill.sh --from-year 2010 --ref main --min 5 --max 20
```

If you must run locally, limit scope (e.g., one month) and use batching with a final push:

```
# Example: January 2010, small density, push to main, rotate at checkpoints
./scripts/graph-backfill.sh --start 2010-01-01 --end 2010-01-31 \
  --min 1 --max 3 --enable-push --remote origin --push-branch main \
  --rotate --batch-size 1000 --push-retries 7 --push-backoff 3
```
