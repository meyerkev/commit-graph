#!/usr/bin/env bash
set -euo pipefail

# Graph backfill: create N random commits per day within a date range.
# Defaults: start=2023-01-01, end=today, min=15, max=100.

START_DATE="2023-01-01"
END_DATE=""
MIN_COMMITS=15
MAX_COMMITS=100
AUTHOR_NAME=""
AUTHOR_EMAIL=""
SEED_FILE=".graph-seed"
SEED_DIR=".graph-seed.d"
DRY_RUN=0
QUIET=0

# Daily batching push/rotate settings
REMOTE="origin"
PUSH_BRANCH=""      # default: push to current branch
ROTATE=0             # default: do not create/switch to new branch at checkpoints
BRANCH_PREFIX="daily"
ENABLE_PUSH=0        # require explicit opt-in to push
PUSH_RETRIES=100     # retry count for git push
PUSH_BACKOFF_SEC=2   # initial backoff seconds; doubles each retry

log() { [ "$QUIET" -eq 1 ] && return 0; printf "%s\n" "$*"; }
die() { printf "Error: %s\n" "$*" >&2; exit 1; }

# Detect GNU date or provide fallbacks
DATE_BIN="date"
if ! date --version >/dev/null 2>&1; then
  if command -v gdate >/dev/null 2>&1; then
    DATE_BIN="gdate"
  else
    DATE_BIN="date" # BSD date – handle with different flags where needed
  fi
fi

is_gnu_date() { $DATE_BIN --version >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --start YYYY-MM-DD       Start date (default: 2023-01-01)
  --end YYYY-MM-DD         End date inclusive (default: today)
  --min N                  Minimum commits per day (default: 15)
  --max N                  Maximum commits per day (default: 100)
  --author-name NAME       Author name to attribute commits
  --author-email EMAIL     Author email to attribute commits
  --file PATH              File to modify for commits (default: .graph-seed)
  --dry-run                Show actions without committing
  --quiet                  Reduce output
  --remote NAME            Remote name to push to (default: origin)
  --push-branch NAME       Remote branch to update (default: current branch name)
  --rotate                 After pushing at a checkpoint, create and switch to a new branch
  --branch-prefix PREFIX   Prefix for rotated branch names (default: daily)
  --enable-push            Actually run git push at checkpoints (default: print only)
  --push-retries N         Number of times to retry failed pushes (default: 100)
  --push-backoff SEC       Initial backoff delay in seconds (default: 2; doubles each retry)
  -h, --help               Show this help

Examples:
  $0 --start 2023-01-01 --end 2024-12-31 --author-name "Jane" \\
     --author-email jane@example.com
  $0 --start "$(date -u -d '7 days ago' +%F)" --end "$(date -u -d 'yesterday' +%F)" --dry-run
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --start) START_DATE=${2:?}; shift 2;;
    --end) END_DATE=${2:?}; shift 2;;
    --min) MIN_COMMITS=${2:?}; shift 2;;
    --max) MAX_COMMITS=${2:?}; shift 2;;
    --author-name) AUTHOR_NAME=${2:?}; shift 2;;
    --author-email) AUTHOR_EMAIL=${2:?}; shift 2;;
    --file) SEED_FILE=${2:?}; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --quiet) QUIET=1; shift;;
    --remote) REMOTE=${2:?}; shift 2;;
    --push-branch) PUSH_BRANCH=${2:?}; shift 2;;
    --rotate) ROTATE=1; shift;;
    --branch-prefix) BRANCH_PREFIX=${2:?}; shift 2;;
    --enable-push) ENABLE_PUSH=1; shift;;
    --push-retries) PUSH_RETRIES=${2:?}; shift 2;;
    --push-backoff) PUSH_BACKOFF_SEC=${2:?}; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

[ -n "$END_DATE" ] || {
  if is_gnu_date; then END_DATE=$($DATE_BIN -u +%F); else END_DATE=$($DATE_BIN -u +%Y-%m-%d); fi
}

[ "$MIN_COMMITS" -le "$MAX_COMMITS" ] || die "--min must be <= --max"
command -v git >/dev/null 2>&1 || die "git not found"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository"

# Auto-detect author identity from git config if not provided
if [ -z "$AUTHOR_EMAIL" ]; then
  AUTHOR_EMAIL=$(git config --get user.email || true)
  [ -n "$AUTHOR_EMAIL" ] || AUTHOR_EMAIL=$(git config --global --get user.email || true)
fi
if [ -z "$AUTHOR_NAME" ]; then
  AUTHOR_NAME=$(git config --get user.name || true)
  [ -n "$AUTHOR_NAME" ] || AUTHOR_NAME=$(git config --global --get user.name || true)
fi

# Date helpers
date_add_days() {
  local d=$1; local days=$2
  if is_gnu_date; then
    $DATE_BIN -u -d "$d + $days day" +%F
  else
    # BSD date
    $DATE_BIN -u -j -v+${days}d -f "%Y-%m-%d" "$d" +%Y-%m-%d
  fi
}

epoch_utc_at_midnight() {
  local d=$1
  if is_gnu_date; then
    $DATE_BIN -u -d "$d 00:00:00" +%s
  else
    # BSD date: parse then output epoch
    $DATE_BIN -u -j -f "%Y-%m-%d %H:%M:%S" "$d 00:00:00" +%s
  fi
}

fmt_iso_utc_from_epoch() {
  local epoch=$1
  if is_gnu_date; then
    $DATE_BIN -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
  else
    $DATE_BIN -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

rand_inclusive() {
  local min=$1 max=$2
  local span=$((max - min + 1))
  # Expand RANDOM to 30 bits
  local r=$(( (RANDOM << 15) | RANDOM ))
  echo $(( min + (r % span) ))
}

count_commits_for_day() {
  local day=$1 since until selector=()
  if is_gnu_date; then
    since="${day}T00:00:00Z"; until="${day}T23:59:59Z"
  else
    since="${day}T00:00:00Z"; until="${day}T23:59:59Z"
  fi
  if [ -n "$AUTHOR_EMAIL" ]; then selector+=("--author=$AUTHOR_EMAIL");
  elif [ -n "$AUTHOR_NAME" ]; then selector+=("--author=$AUTHOR_NAME"); fi
  git rev-list --count HEAD --since "$since" --until "$until" "${selector[@]}" 2>/dev/null || echo 0
}

ensure_seed_file() {
  mkdir -p "$(dirname "$SEED_FILE")"
  [ -f "$SEED_FILE" ] || echo "# seed" > "$SEED_FILE"
}

# Generate a random timestamp within a given day
get_random_timestamp() {
  local day=$1
  local base_epoch offset ts_epoch
  base_epoch=$(epoch_utc_at_midnight "$day")
  offset=$(rand_inclusive 0 86399)
  ts_epoch=$(( base_epoch + offset ))
  fmt_iso_utc_from_epoch "$ts_epoch"
}

# Make a commit with a random timestamp within the current day
make_timestamped_commit() {
  local day=$1 msg=$2
  local ts_iso
  ts_iso=$(get_random_timestamp "$day")
  make_commit_at "$ts_iso" "$msg"
}

# Make a commit at a specific timestamp
make_commit_at() {
  local ts_iso=$1 msg=$2
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY: commit at $ts_iso — $msg"
    return 0
  fi
  printf "%s\n" "$ts_iso $RANDOM" >> "$SEED_FILE"
  git add "$SEED_FILE"
  GIT_AUTHOR_DATE="$ts_iso" GIT_COMMITTER_DATE="$ts_iso" \
    git commit -m "$msg"
}

# Remove the seed file/directory and commit its removal
# Respects DRY_RUN mode and only removes if file/directory exists
remove_seed_file() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY: Would remove $SEED_FILE and $SEED_FILE.d/"
    log "DRY: Would commit removal"
    return 0
  fi
  
  local has_changes=0
  
  # Remove single file if it exists and hasn't been removed yet
  if [ -f "$SEED_FILE" ];  then
    log "Removing $SEED_FILE"
    git rm -f "$SEED_FILE" || true
    has_changes=1
  fi
  
  # Handle directory contents
  # Only remove seed directory if it contains files
  if [ -d "$SEED_DIR" ] && [ -n "$(ls -A "$SEED_DIR" 2>/dev/null)" ]; then
    git rm -rf "$SEED_DIR" || true
    has_changes=1
  fi
  
  # Only commit if we actually removed something
  if [ "$has_changes" -eq 1 ]; then
    make_timestamped_commit "$current_day" "chore(cleanup): remove graph seed files" || true
    log "Successfully removed and committed seed files"
  fi
  ensure_seed_file
}

# Daily helpers
current_branch_name() { git rev-parse --abbrev-ref HEAD; }

git_push_with_retry() {
  local remote=$1 curr=$2 push_ref=$3
  if [ "$DRY_RUN" -eq 1 ] || [ "$ENABLE_PUSH" -eq 0 ]; then
    [ "$ENABLE_PUSH" -eq 1 ] || log "INFO: push disabled. Use --enable-push to actually push."
    log "DRY: would push $curr -> $push_ref on $remote"
    return 0
  fi
  local attempt=1 delay=$PUSH_BACKOFF_SEC rc=0
  while :; do
    if git push "$remote" "$curr":"$push_ref"; then
      return 0
    fi
    rc=$?
    if [ "$attempt" -ge "$PUSH_RETRIES" ]; then
      log "WARN: push failed after $attempt attempts (rc=$rc)"
      return "$rc"
    fi
    # Back off BEFORE fetching/merging so the window between merge and push is minimal
    log "WARN: push failed (attempt $attempt/$PUSH_RETRIES); backing off ${delay}s before fetch+merge..."
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
    # Now fetch and merge latest remote and immediately loop to push again
    if ! git fetch "$remote" "$push_ref"; then
      log "WARN: fetch failed; will retry push without merge"
    else
      # Prefer keeping our local changes in conflicts (seed file is append-only)
      git config --local merge.renamelimit 999999 || true
      if ! git merge -s recursive -X ours --no-edit "origin/${push_ref}"; then
        log "WARN: merge failed; attempting to abort"
        git merge --abort || true
      fi
    fi
  done
}

push_checkpoint() {
  local curr push_ref new_branch ts
  curr=$(current_branch_name)
  push_ref=${PUSH_BRANCH:-$curr}
  ts=$(if is_gnu_date; then $DATE_BIN -u +%Y%m%d-%H%M%S; else $DATE_BIN -u +%Y%m%d-%H%M%S; fi)
  new_branch="${BRANCH_PREFIX}-${ts}"

  if [ "$DRY_RUN" -eq 1 ] || [ "$ENABLE_PUSH" -eq 0 ]; then
    [ "$ENABLE_PUSH" -eq 1 ] || log "INFO: push disabled. Use --enable-push to actually push."
    log "DRY: checkpoint $ts — would push $curr -> $push_ref on $REMOTE"
    if [ "$ROTATE" -eq 1 ]; then
      log "DRY: would create and switch to new branch: $new_branch"
    fi
    return 0
  fi

  log "Checkpoint $ts: pushing $curr -> $push_ref on $REMOTE"
  remove_seed_file
  
  if git_push_with_retry "$REMOTE" "$curr" "$push_ref"; then
    if [ "$ROTATE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
      log "Rotating branch: $new_branch"
      git checkout -b "$new_branch"
    fi
  else
    log "WARN: checkpoint push failed; skipping rotation"
  fi
}

log "Backfilling from $START_DATE to $END_DATE (min=$MIN_COMMITS, max=$MAX_COMMITS)"
ensure_seed_file

# Optional: if both provided explicitly, set repo-local config
if [ -n "${AUTHOR_NAME}" ] && [ -n "${AUTHOR_EMAIL}" ]; then
  if [ "$DRY_RUN" -eq 0 ] && [ -n "${AUTHOR_NAME}" ] && [ -n "${AUTHOR_EMAIL}" ]; then
    git config user.name "$AUTHOR_NAME"
    git config user.email "$AUTHOR_EMAIL"
  fi
fi

current_day="$START_DATE"
while :; do
  ensure_seed_file
  [ "$current_day" \> "$END_DATE" ] && break
  target=$(rand_inclusive "$MIN_COMMITS" "$MAX_COMMITS")
  need=$target
  if [ "$need" -le 0 ]; then
    log "$current_day: existing=$existing >= target=$target — skip"
  else
    log "$current_day: existing=$existing, target=$target, need=$need"
    base_epoch=$(epoch_utc_at_midnight "$current_day")
    for i in $(seq 1 "$need"); do
      make_timestamped_commit "$current_day" "chore(graph): seed $current_day (#$i/$need)"
    done
  fi
  remove_seed_file
  push_checkpoint
  current_day=$(date_add_days "$current_day" 1)
done

# Final cleanup is handled by the workflow's push step
# We only need to ensure the seed files are staged for removal
# Only clean up if seed file exists or seed directory has files
if [ -f "$SEED_FILE" ] || ([ -d "$SEED_DIR" ] && [ -n "$(ls -A "$SEED_DIR" 2>/dev/null)" ]); then
  log "Staging seed files for removal"
  git add "$SEED_DIR" "$SEED_FILE" 2>/dev/null || true
  git rm -rf "$SEED_DIR" "$SEED_FILE" 2>/dev/null || true
  make_timestamped_commit "$current_day" "chore(cleanup): remove graph seed files"
fi

log "Done."

push_checkpoint
