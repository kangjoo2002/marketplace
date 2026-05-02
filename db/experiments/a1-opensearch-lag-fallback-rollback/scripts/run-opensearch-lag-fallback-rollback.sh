#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -ExecutionPolicy Bypass -File "${SCRIPT_DIR}/run-opensearch-lag-fallback-rollback.ps1"
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "${SCRIPT_DIR}/run-opensearch-lag-fallback-rollback.ps1")"
else
  echo "PowerShell was not found. Run run-opensearch-lag-fallback-rollback.ps1 from PowerShell." >&2
  exit 1
fi
