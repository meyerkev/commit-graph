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
DRY_RUN=0
QUIET=0

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
  [ "$current_day" \> "$END_DATE" ] && break
  existing=$(count_commits_for_day "$current_day") || existing=0
  target=$(rand_inclusive "$MIN_COMMITS" "$MAX_COMMITS")
  need=$(( target - existing ))
  if [ "$need" -le 0 ]; then
    log "$current_day: existing=$existing >= target=$target — skip"
  else
    log "$current_day: existing=$existing, target=$target, need=$need"
    base_epoch=$(epoch_utc_at_midnight "$current_day")
    for i in $(seq 1 "$need"); do
      offset=$(rand_inclusive 0 86399)
      ts_epoch=$(( base_epoch + offset ))
      ts_iso=$(fmt_iso_utc_from_epoch "$ts_epoch")
      make_commit_at "$ts_iso" "chore(graph): seed $current_day (#$i/$need)"
    done
  fi
  current_day=$(date_add_days "$current_day" 1)
done

log "Done."
