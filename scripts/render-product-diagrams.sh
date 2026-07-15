#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNPM_BIN="${PNPM_BIN:-pnpm}"
MERMAID_CLI_PACKAGE="${MERMAID_CLI_PACKAGE:-@mermaid-js/mermaid-cli@11.16.0}"

if [ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ] && \
  [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  export PUPPETEER_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi

render_dir="$(mktemp -d "$ROOT/diagrams/.product-render.XXXXXX")"
trap 'rm -rf "$render_dir"' EXIT HUP INT TERM

render_format() {
  format="$1"
  for source in "$ROOT"/diagrams/product-*.mmd; do
    base="${source%.mmd}"
    name="$(basename "$base")"
    "$PNPM_BIN" dlx "$MERMAID_CLI_PACKAGE" \
      --input "$source" \
      --output "$render_dir/${name}.${format}" \
      --theme neutral \
      --backgroundColor white \
      --width 1800
  done
}

render_format svg &
svg_pid=$!
render_format png &
png_pid=$!

if wait "$svg_pid"; then
  svg_status=0
else
  svg_status=$?
fi
if wait "$png_pid"; then
  png_status=0
else
  png_status=$?
fi

if [ "$svg_status" -ne 0 ] || [ "$png_status" -ne 0 ]; then
  exit 1
fi

source_count=0
for source in "$ROOT"/diagrams/product-*.mmd; do
  name="$(basename "${source%.mmd}")"
  source_count=$((source_count + 1))
  test -s "$render_dir/${name}.svg"
  test -s "$render_dir/${name}.png"
  file "$render_dir/${name}.svg" | grep -q "SVG"
  file "$render_dir/${name}.png" | grep -q "PNG"
done
test "$source_count" -eq 10

for output in "$render_dir"/product-*.svg "$render_dir"/product-*.png; do
  mv -f "$output" "$ROOT/diagrams/$(basename "$output")"
done
