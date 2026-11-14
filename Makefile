.PHONY: sync check lint test

# Regenerate hook files and manifest metadata (see scripts/sync.sh).
sync:
	scripts/sync.sh

# Fail if generated files are out of date.
check: sync
	git diff --exit-code -- plugins/ram-guard/hooks hooks .claude-plugin plugins/ram-guard/.claude-plugin gemini-extension.json

lint:
	shellcheck plugins/ram-guard/scripts/ram-guard.sh install.sh scripts/*.sh tests/*.sh

test:
	tests/test.sh
