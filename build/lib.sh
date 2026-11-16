#!/usr/bin/env bash
# Shared helpers for the CasperOS build stages.
set -u

info() { printf '\033[1;36m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── failure reporting ──────────────────────────────────────────────────────
# set -e turns any failing command into "exit 1" with no clue which command it
# was, and a CI step that echoes thousands of lines buries it. GitHub renders
# its ::error:: workflow command as a check-run annotation, i.e. a single line
# next to the job - so name the exact command and line there.
casper_on_error() {
    local rc=$? src="${BASH_SOURCE[1]:-?}" line="${BASH_LINENO[0]:-?}"
    printf '\n\033[1;31m✗ FAILED (exit %s) at %s:%s\033[0m\n  command: %s\n' \
        "$rc" "$src" "$line" "$BASH_COMMAND" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error::exit %s at %s:%s -> %s\n' \
            "$rc" "${src##*/}" "$line" "$BASH_COMMAND" >&2
    fi
}
set -o errtrace 2>/dev/null || true
trap casper_on_error ERR
