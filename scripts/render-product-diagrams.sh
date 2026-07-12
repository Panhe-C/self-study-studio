#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNPM_BIN="${PNPM_BIN:-pnpm}"
MERMAID_CLI_PACKAGE="${MERMAID_CLI_PACKAGE:-@mermaid-js/mermaid-cli@11.16.0}"

if [[ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]] && \
  [[ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]]; then
  export PUPPETEER_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi

for source in "$ROOT"/diagrams/product-*.mmd; do
  base="${source%.mmd}"
  for format in svg png; do
    output="${base}.${format}"
    if [[ -f "$output" ]] && [[ ! "$source" -nt "$output" ]]; then
      continue
    fi
    "$PNPM_BIN" dlx "$MERMAID_CLI_PACKAGE" \
      --input "$source" \
      --output "$output" \
      --backgroundColor transparent \
      --width 1800
  done
done
