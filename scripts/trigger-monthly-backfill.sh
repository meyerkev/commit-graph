#!/usr/bin/env bash
set -euo pipefail

# Trigger monthly workflow_dispatch runs of backfill.yml for each month since a given year.
# Requires a GitHub token with repo:write (set via GITHUB_TOKEN or --token).
#
# Example:
#   GITHUB_TOKEN=ghp_xxx ./scripts/trigger-monthly-backfill.sh --from-year 2010 \
#     --repo meyerkev/commit-graph --ref main --dry-run
#

FROM_YEAR=2010
TO_YEAR=""            # default: current year
REPO=""               # default: derived from git remote
REF=""                # default: repo default or current branch, else 'main'
WORKFLOW="backfill.yml"
MIN=""                # optional override of min commits
MAX=""                # optional override of max commits
TOKEN="${GITHUB_TOKEN:-}"
DRY_RUN=0
QUIET=0

log() { [ "$QUIET" -eq 1 ] && return 0; printf "%s\n" "$*"; }
die() { printf "Error: %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --from-year YYYY        First year to trigger (default: 2010)
  --to-year YYYY          Last year to trigger (default: current year)
  --repo OWNER/REPO       Target repo (default: derive from git origin)
  --ref BRANCH            Git ref to dispatch (default: default branch or 'main')
  --workflow FILE|ID      Workflow file name or ID (default: backfill.yml)
  --min N                 Optional min commits per day override
  --max N                 Optional max commits per day override
  --token TOKEN           GitHub token (default: env GITHUB_TOKEN)
  --dry-run               Show planned dispatches without calling API
  --quiet                 Reduce output
  -h, --help              Show this help

The workflow receives inputs range_start and range_end per calendar month.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-year) FROM_YEAR=${2:?}; shift 2;;
    --to-year) TO_YEAR=${2:?}; shift 2;;
    --repo) REPO=${2:?}; shift 2;;
    --ref) REF=${2:?}; shift 2;;
    --workflow) WORKFLOW=${2:?}; shift 2;;
    --min) MIN=${2:?}; shift 2;;
    --max) MAX=${2:?}; shift 2;;
    --token) TOKEN=${2:?}; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --quiet) QUIET=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

command -v git >/dev/null 2>&1 || die "git not found"

# Date helpers (GNU/BSD compatible)
DATE_BIN="date"
if ! date --version >/dev/null 2>&1; then
  if command -v gdate >/dev/null 2>&1; then DATE_BIN="gdate"; else DATE_BIN="date"; fi
fi
is_gnu_date() { $DATE_BIN --version >/dev/null 2>&1; }

current_year() { $DATE_BIN -u +%Y; }
fmt_y_m_d() { if is_gnu_date; then $DATE_BIN -u -d "$1" +%F; else $DATE_BIN -u -j -f "%Y-%m-%d" "$1" +%Y-%m-%d; fi; }
first_day_of_month() { printf "%04d-%02d-01\n" "$1" "$2"; }
date_add_days() {
  local d=$1; local days=$2
  if is_gnu_date; then
    $DATE_BIN -u -d "$d $days day" +%F
  else
    $DATE_BIN -u -j -f "%Y-%m-%d" "$d" -v${days}d +%Y-%m-%d
  fi
}

is_leap() { local y=$1; ( [ $((y % 400)) -eq 0 ] || { [ $((y % 4)) -eq 0 ] && [ $((y % 100)) -ne 0 ]; } ) && return 0 || return 1; }
last_day_of_month() {
  local y=$1 m=$2 d=31
  case $m in
    1|3|5|7|8|10|12) d=31 ;;
    4|6|9|11) d=30 ;;
    2) if is_leap "$y"; then d=29; else d=28; fi ;;
    *) d=31 ;;
  esac
  printf "%04d-%02d-%02d\n" "$y" "$m" "$d"
}

[ -n "$TO_YEAR" ] || TO_YEAR=$(current_year)

if [ -z "$REPO" ]; then
  # Try to derive from git origin url
  origin=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$origin" ]; then
    case "$origin" in
      git@github.com:*) REPO=${origin#git@github.com:}; REPO=${REPO%.git};;
      https://github.com/*) REPO=${origin#https://github.com/}; REPO=${REPO%.git};;
    esac
  fi
fi
[ -n "$REPO" ] || die "--repo not set and could not derive from origin"

if [ -z "$REF" ]; then
  # Try to detect default branch from local HEAD; fallback to 'main'
  REF=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
fi

[ -n "$TOKEN" ] || die "GitHub token not provided (set GITHUB_TOKEN or use --token)"

log "Dispatching workflow '$WORKFLOW' on $REPO ($REF) for months ${FROM_YEAR}..${TO_YEAR}"

dispatch() {
  local start=$1 end=$2
  local json_inputs="{\"range_start\":\"$start\",\"range_end\":\"$end\"}"
  if [ -n "$MIN" ]; then json_inputs=${json_inputs/\}/,\"min\":\"$MIN\"} ; fi
  if [ -n "$MAX" ]; then json_inputs=${json_inputs/\}/,\"max\":\"$MAX\"} ; fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY: dispatch $WORKFLOW ref=$REF inputs=$json_inputs"
    return 0
  fi
  curl -sS -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${TOKEN}" \
    "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "{\"ref\":\"${REF}\",\"inputs\":${json_inputs}}" >/dev/null
}

for y in $(seq "$FROM_YEAR" "$TO_YEAR"); do
  for m in $(seq 1 12); do
    start=$(first_day_of_month "$y" "$m")
    end=$(last_day_of_month "$y" "$m")
    log "Queue: $start .. $end"
    dispatch "$start" "$end" || {
      echo "Warning: dispatch failed for $start..$end" >&2
    }
    # small pace to avoid rate-limits
    sleep 0.3
  done
done

log "Done."
