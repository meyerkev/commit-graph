#!/usr/bin/env bash
set -euo pipefail

# Cancel queued/in_progress workflow runs for a given workflow.
# Requires a GitHub token with repo:write (set via GITHUB_TOKEN or --token).
#
# Example:
#   GITHUB_TOKEN=ghp_xxx ./scripts/cancel-workflow-runs.sh \
#     --repo meyerkev/commit-graph --workflow backfill.yml --statuses queued,in_progress

REPO=""
WORKFLOW="backfill.yml"   # file name or numeric ID
STATUSES="queued,in_progress,requested,waiting"
TOKEN="${GITHUB_TOKEN:-}"
DRY_RUN=0
QUIET=0

log() { [ "$QUIET" -eq 1 ] && return 0; printf "%s\n" "$*"; }
die() { printf "Error: %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --repo OWNER/REPO       Target repository (required)
  --workflow FILE|ID      Workflow file name or ID (default: backfill.yml)
  --statuses LIST         Comma list: queued,in_progress,requested,waiting (default: all)
  --token TOKEN           GitHub token (default: env GITHUB_TOKEN)
  --dry-run               Only print intended cancellations
  --quiet                 Reduce output
  -h, --help              Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:?}; shift 2;;
    --workflow) WORKFLOW=${2:?}; shift 2;;
    --statuses) STATUSES=${2:?}; shift 2;;
    --token) TOKEN=${2:?}; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --quiet) QUIET=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

[ -n "$REPO" ] || die "--repo is required"
[ -n "$TOKEN" ] || die "GitHub token not provided (set GITHUB_TOKEN or use --token)"

api() {
  local method=$1 url=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl -sS -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${TOKEN}" \
      "$url" \
      -d "$data"
  else
    curl -sS -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${TOKEN}" \
      "$url"
  fi
}

# Resolve workflow to ID if a file name was provided
WORKFLOW_ID="$WORKFLOW"
if ! [[ "$WORKFLOW" =~ ^[0-9]+$ ]]; then
  # List workflows and find ID by file name/path
  wf_json=$(api GET "https://api.github.com/repos/${REPO}/actions/workflows")
  WORKFLOW_ID=$(node -e '
    let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{
      try{const j=JSON.parse(d);const w=j.workflows||[];const t=(process.argv[1]||"").toLowerCase();
        const hit=w.find(x=>String(x.path||"").toLowerCase().endsWith(t)||String(x.name||"").toLowerCase()===t);
        if(hit&&hit.id)process.stdout.write(String(hit.id));}catch(e){}
    });
  ' "$WORKFLOW")
  [ -n "$WORKFLOW_ID" ] || die "Could not resolve workflow ID for '$WORKFLOW'"
fi

log "Workflow ${WORKFLOW} -> ID ${WORKFLOW_ID}"

IFS=',' read -r -a status_arr <<< "$STATUSES"
to_cancel=()
for st in "${status_arr[@]}"; do
  page=1
  while :; do
    url="https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW_ID}/runs?per_page=100&page=${page}&status=${st}"
    runs_json=$(api GET "$url")
    ids=$(node -e '
      let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{
        try{const j=JSON.parse(d);const arr=(j.workflow_runs||[]).map(r=>r.id);console.log(arr.join("\n"));}catch(e){}}
      );
    ' <<< "$runs_json")
    # shellcheck disable=SC2206
    ids_arr=( $ids )
    [ ${#ids_arr[@]} -gt 0 ] || break
    to_cancel+=( "${ids_arr[@]}" )
    [ ${#ids_arr[@]} -lt 100 ] && break
    page=$((page + 1))
  done
done

unique_ids=$(printf "%s\n" "${to_cancel[@]:-}" | awk '!seen[$0]++')
count=$(printf "%s\n" "$unique_ids" | sed '/^$/d' | wc -l | tr -d ' ')
log "Found ${count} runs to cancel"

printf "%s\n" "$unique_ids" | while read -r id; do
  [ -n "$id" ] || continue
  log "Cancel run ${id}"
  if [ "$DRY_RUN" -eq 1 ]; then continue; fi
  api POST "https://api.github.com/repos/${REPO}/actions/runs/${id}/cancel" >/dev/null || {
    echo "Warn: cancel failed for run ${id}" >&2
  }
done

log "Done."

