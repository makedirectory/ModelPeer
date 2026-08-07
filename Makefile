.PHONY: test lint

test:
	bash tests/smoke.sh

lint:
	bash -n bin/model-peer bin/ask-claude bin/ask-codex bin/ask-gemini bin/ai-review install.sh uninstall.sh tests/smoke.sh
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck bin/* install.sh uninstall.sh tests/smoke.sh; else echo "shellcheck not installed; skipped"; fi
