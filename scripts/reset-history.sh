#!/usr/bin/env bash
set -euo pipefail

# Reset git history to a single clean commit

DRY_RUN=0
QUIET=0

log() { [ "$QUIET" -eq 1 ] && return 0; printf "%s\n" "$*"; }
die() { printf "Error: %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --dry-run       Show actions without executing
  --quiet         Reduce output
  -h, --help      Show this help

Example:
  $0 --dry-run
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --quiet) QUIET=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

# Safety checks
command -v git >/dev/null 2>&1 || die "git not found"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$CURRENT_BRANCH" = "main" ] || die "Must be on main branch"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: Would reset git history to a single commit"
  exit 0
fi

# Create a new orphan branch
log "Creating new history..."
git checkout --orphan temp
git add -A

# Create a single commit with the current state
log "Creating clean commit..."
git commit -m "chore: reset repository history"

# Backup the current main branch
OLD_MAIN="main-backup-$(date +%s)"
git branch -m "$CURRENT_BRANCH" "$OLD_MAIN"

# Make our new branch the main branch
git branch -m main

# Force push to remote
log "Pushing new history..."
git push -f origin main

log "Successfully reset history. Old history saved in $OLD_MAIN"
log "Note: You may want to delete the backup branch with: git branch -D $OLD_MAIN"
