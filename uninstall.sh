#!/usr/bin/env bash
set -euo pipefail
BIN_DIR="${MODEL_PEER_BIN_DIR:-$HOME/.local/bin}"
for cmd in model-peer ask-claude ask-codex ask-gemini ai-review; do
  rm -f "$BIN_DIR/$cmd"
done
printf 'Removed Model Peer commands from %s\n' "$BIN_DIR"
printf 'Vendor CLIs, credentials, and configuration were left untouched.\n'
