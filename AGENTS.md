# Repository Guidelines

This repository exists to generate commit activity for a GitHub contribution graph. Keep changes minimal, scriptable, and safe to run locally without polluting real projects.

## Project Structure & Module Organization
- `scripts/` — Bash scripts for generating commits, utilities, and helpers.
- `tests/` — Optional Bats/shell tests; name files `test_*.bats`.
- `templates/` — Commit message templates or schedules (e.g., `.txt`, `.json`).
- `tmp/` — Ignored scratch repos for local testing (add to `.gitignore`).
- Root contains `README.md`, `LICENSE`, and this guide.

## Build, Test, and Development Commands
- No build step. Scripts should run with system Git and Bash.
- Create a scratch repo for safe testing:
  - `tmp=$(mktemp -d) && git init "$tmp" && (cd "$tmp" && git commit --allow-empty -m "init")`
- Example dry run (adapt to your script name/flags):
  - `(cd "$tmp" && ../../scripts/commit-burst.sh --dry-run --days 7)`
- Lint shell scripts:
  - `shellcheck scripts/*.sh`

## Coding Style & Naming Conventions
- Bash only for portability: `#!/usr/bin/env bash` with `set -euo pipefail`.
- Indentation: 2 spaces; UTF‑8 files with newline at EOF.
- Filenames: lowercase kebab-case (e.g., `commit-burst.sh`).
- Functions/vars: `snake_case`; constants: `UPPER_SNAKE`.
- Prefer small, composable scripts in `scripts/` with `--help` output.

## Testing Guidelines
- Provide a `--dry-run` mode that logs intended commits without writing.
- Tests live in `tests/`; prefer Bats. Name tests `test_*.bats`.
- Cover: flag parsing, scheduling boundaries (weekends/holidays), idempotency, and time zone handling.
- When possible, run in a temp repo (`mktemp -d`) and clean up.

## Commit & Pull Request Guidelines
- Commits: imperative mood, concise scope. Examples:
  - `feat: add density flag for weekday bursts`
  - `fix: handle empty template list gracefully`
  - `chore: shellcheck and formatting`
- PRs must include:
  - Purpose, notable flags/parameters, and sample output (logs). Optional: screenshot of a local graph.
  - Steps to test in a scratch repo and any risk notes.

## Security & Configuration Tips
- Never target real repos by default; require explicit `--repo` or run in CWD with confirmation.
- Do not commit personal config, tokens, or machine-specific paths. Provide `.env.example` if configuration is needed.
- Respect `.gitignore`; write temp artifacts to `tmp/`.

