.PHONY: test lint sync check-sync

test: check-sync
	bash tests/smoke.sh

lint:
	bash -n bin/model-peer bin/ask-claude bin/ask-codex bin/ask-gemini bin/ai-review install.sh uninstall.sh tests/smoke.sh tools/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck bin/* install.sh uninstall.sh tests/smoke.sh tools/*.sh; else echo "shellcheck not installed; skipped"; fi

# install.sh embeds a verbatim copy of bin/model-peer so the curl install path
# stays standalone. This project also runs `model-peer init` on itself, so its own
# .claude/.codex/.gemini skills are refreshed here too.
sync:
	bash tools/sync-installer.sh
	bash bin/model-peer update

check-sync:
	@sed -n "/<<'__MODEL_PEER__'/,/^__MODEL_PEER__$$/p" install.sh | sed '1d;$$d' | diff -q - bin/model-peer >/dev/null \
		|| { echo "install.sh is out of sync with bin/model-peer; run: make sync" >&2; exit 1; }
	@bash bin/model-peer update --check >/dev/null \
		|| { echo "this repo's own skills are stale; run: make sync" >&2; exit 1; }
