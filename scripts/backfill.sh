#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 MM/DD/YYYY [extra-args]

Runs a one-day backfill using scripts/graph-backfill.sh.
Extra args are forwarded (e.g., --min 15 --max 100).
EOF
}

[ $# -ge 1 ] || { usage; exit 1; }
INPUT_DATE=$1; shift || true

# Detect GNU date or BSD date (macOS)
DATE_BIN="date"
IS_GNU=0
if date --version >/dev/null 2>&1; then
  DATE_BIN="date"; IS_GNU=1
elif command -v gdate >/dev/null 2>&1; then
  DATE_BIN="gdate"; IS_GNU=1
else
  DATE_BIN="date"; IS_GNU=0
fi

# Convert to ISO YYYY-MM-DD
if [ "$IS_GNU" -eq 1 ]; then
  ISO=$($DATE_BIN -u -d "$INPUT_DATE" +%F)
else
  # Try MM/DD/YYYY first, else assume already ISO
  if ISO=$($DATE_BIN -u -j -f "%m/%d/%Y" "$INPUT_DATE" +%Y-%m-%d 2>/dev/null); then :; else
    ISO=$($DATE_BIN -u -j -f "%Y-%m-%d" "$INPUT_DATE" +%Y-%m-%d)
  fi
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/graph-backfill.sh" --start "$ISO" --end "$ISO" "$@"

