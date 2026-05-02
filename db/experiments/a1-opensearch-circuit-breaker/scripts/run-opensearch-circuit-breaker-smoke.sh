#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -ExecutionPolicy Bypass -File "${SCRIPT_DIR}/run-opensearch-circuit-breaker-smoke.ps1"
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "${SCRIPT_DIR}/run-opensearch-circuit-breaker-smoke.ps1")"
else
  echo "PowerShell was not found. Run run-opensearch-circuit-breaker-smoke.ps1 from PowerShell." >&2
  exit 1
fi
