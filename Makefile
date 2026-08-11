.PHONY: test lint sync check-sync

test: check-sync
	bash tests/smoke.sh

lint:
	bash -n bin/model-peer bin/ask-claude bin/ask-codex bin/ask-gemini bin/ai-review install.sh uninstall.sh tests/smoke.sh tools/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck bin/* install.sh uninstall.sh tests/smoke.sh tools/*.sh; else echo "shellcheck not installed; skipped"; fi

# install.sh embeds a verbatim copy of bin/model-peer so the curl install path
# stays standalone, and examples/SKILL.md must match what `model-peer init`
# writes. Regenerate both after any change to bin/model-peer.
sync:
	bash tools/sync-installer.sh
	bash bin/model-peer init --print > examples/SKILL.md
	@echo "sync: examples/SKILL.md now matches 'model-peer init --print'."

check-sync:
	@sed -n "/<<'__MODEL_PEER__'/,/^__MODEL_PEER__$$/p" install.sh | sed '1d;$$d' | diff -q - bin/model-peer >/dev/null \
		|| { echo "install.sh is out of sync with bin/model-peer; run: make sync" >&2; exit 1; }
	@bash bin/model-peer init --print | diff -q - examples/SKILL.md >/dev/null \
		|| { echo "examples/SKILL.md is out of sync with the skill template; run: make sync" >&2; exit 1; }
