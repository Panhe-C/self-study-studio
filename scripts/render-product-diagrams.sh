#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNPM_BIN="${PNPM_BIN:-pnpm}"
MERMAID_CLI_PACKAGE="${MERMAID_CLI_PACKAGE:-@mermaid-js/mermaid-cli@11.16.0}"

if [ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ] && \
  [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  export PUPPETEER_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi

render_format() {
  format="$1"
  for source in "$ROOT"/diagrams/product-*.mmd; do
    base="${source%.mmd}"
    output="${base}.${format}"
    "$PNPM_BIN" dlx "$MERMAID_CLI_PACKAGE" \
      --input "$source" \
      --output "$output" \
      --theme neutral \
      --backgroundColor white \
      --width 1800
  done
}

render_format svg &
svg_pid=$!
render_format png &
png_pid=$!
wait "$svg_pid"
wait "$png_pid"
