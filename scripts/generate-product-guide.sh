#!/bin/sh

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_DIR="$REPO_ROOT/docs/product-guide"
SCRATCH_ROOT="${TMPDIR:-/tmp}/codex-presentations/self-study-studio-product-guide"
WORKSPACE_DIR="$SCRATCH_ROOT/workspace"
PREVIEW_DIR="$SCRATCH_ROOT/preview"

RUNTIME_ROOT="${CODEX_RUNTIME_ROOT:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies}"
NODE_BIN="${NODE_BIN:-$RUNTIME_ROOT/node/bin/node}"
PYTHON_BIN="${PYTHON_BIN:-$RUNTIME_ROOT/python/bin/python3}"
PRESENTATIONS_SKILL_DIR="${PRESENTATIONS_SKILL_DIR:-$HOME/.codex/plugins/cache/openai-primary-runtime/presentations/26.709.11516/skills/presentations}"
SETUP_SCRIPT="$PRESENTATIONS_SKILL_DIR/container_tools/setup_artifact_tool_workspace.mjs"

if [ ! -x "$NODE_BIN" ]; then
  echo "Bundled Node.js not found: $NODE_BIN" >&2
  exit 1
fi

if [ ! -x "$PYTHON_BIN" ]; then
  echo "Bundled Python not found: $PYTHON_BIN" >&2
  exit 1
fi

if [ ! -f "$SETUP_SCRIPT" ]; then
  echo "Presentation workspace setup script not found: $SETUP_SCRIPT" >&2
  exit 1
fi

mkdir -p "$WORKSPACE_DIR" "$PREVIEW_DIR" "$OUTPUT_DIR"

if [ ! -e "$WORKSPACE_DIR/node_modules/@oai/artifact-tool" ]; then
  "$NODE_BIN" "$SETUP_SCRIPT" --workspace "$WORKSPACE_DIR"
fi

ln -sf "$REPO_ROOT/scripts/generate-product-guide.mjs" "$WORKSPACE_DIR/generate-product-guide.mjs"

"$NODE_BIN" --preserve-symlinks-main "$WORKSPACE_DIR/generate-product-guide.mjs" \
  --repo-root "$REPO_ROOT" \
  --output-dir "$OUTPUT_DIR" \
  --scratch-dir "$PREVIEW_DIR"

"$PYTHON_BIN" "$REPO_ROOT/scripts/build-product-guide-pdf.py" \
  "$PREVIEW_DIR/a4" \
  "$OUTPUT_DIR/self-study-studio-product-guide-a4.pdf"

echo "Generated Canva-ready product guide files in $OUTPUT_DIR"
