#!/usr/bin/env bash
set -euo pipefail

# Clean git history from a specific date by removing all commits made on that day

TARGET_DATE=""
DRY_RUN=0
QUIET=0

log() { [ "$QUIET" -eq 1 ] && return 0; printf "%s\n" "$*"; }
die() { printf "Error: %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options] --date YYYY-MM-DD

Options:
  --date YYYY-MM-DD    Date to clean (required)
  --dry-run           Show actions without executing
  --quiet             Reduce output
  -h, --help          Show this help

Example:
  $0 --date 2023-12-25
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --date) TARGET_DATE=${2:?}; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --quiet) QUIET=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

# Validate required arguments
[ -n "$TARGET_DATE" ] || die "Missing required --date argument"
[[ "$TARGET_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Invalid date format. Use YYYY-MM-DD"

# Safety checks
command -v git >/dev/null 2>&1 || die "git not found"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository"

# Get the start and end timestamps for the target date in ISO format
if date --version >/dev/null 2>&1; then
  # GNU date
  START_TIME=$(date -u -d "$TARGET_DATE 00:00:00" +"%Y-%m-%dT%H:%M:%SZ")
  END_TIME=$(date -u -d "$TARGET_DATE 23:59:59" +"%Y-%m-%dT%H:%M:%SZ")
else
  # BSD date
  START_TIME=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$TARGET_DATE 00:00:00" +"%Y-%m-%dT%H:%M:%SZ")
  END_TIME=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$TARGET_DATE 23:59:59" +"%Y-%m-%dT%H:%M:%SZ")
fi

# Get all commits for the target date
log "Finding commits between $START_TIME and $END_TIME"
COMMITS=$(git log --after="$START_TIME" --before="$END_TIME" --format="%H")

if [ -z "$COMMITS" ]; then
  log "No commits found for $TARGET_DATE"
  exit 0
fi

# Count commits to remove
COMMIT_COUNT=$(echo "$COMMITS" | wc -l)
log "Found $COMMIT_COUNT commits to remove"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: Would remove the following commits:"
  git log --after="$START_TIME" --before="$END_TIME" --oneline
  exit 0
fi

# Create a temporary branch for our work
TEMP_BRANCH="cleanup-$(date +%s)"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "Creating temporary branch $TEMP_BRANCH"
git checkout -b "$TEMP_BRANCH"

# Find the first commit before our target date
FIRST_COMMIT=$(git log --before="$START_TIME" -n 1 --format="%H")
if [ -z "$FIRST_COMMIT" ]; then
  die "No commits found before $TARGET_DATE"
fi

# Use interactive rebase to drop the commits
log "Removing commits..."
git rebase -i "$FIRST_COMMIT" --exec \
  "if [[ \$(git show -s --format=%aI HEAD) =~ ^${TARGET_DATE} ]]; then git reset --hard HEAD~; fi"

# Switch back to original branch and force-update it
log "Updating $CURRENT_BRANCH"
git checkout "$CURRENT_BRANCH"
git reset --hard "$TEMP_BRANCH"

# Clean up temporary branch
git branch -D "$TEMP_BRANCH"

log "Successfully removed $COMMIT_COUNT commits from $TARGET_DATE"
log "Note: You will need to force-push these changes if the branch was already pushed"
