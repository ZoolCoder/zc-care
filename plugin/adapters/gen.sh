#!/bin/sh
# Copies COMMON.md into every adapter, between its <!-- common:start --> and
# <!-- common:end --> markers. Edit COMMON.md, run `sh plugin/adapters/gen.sh`.
# TestAdaptersCarryCommon fails when a copy drifts.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
for file in cloud/AGENTS.md codex/AGENTS.md copilot/copilot-instructions.md cursor/zc-care.mdc gemini/GEMINI.md; do
	target=$here/$file
	for marker in '<!-- common:start -->' '<!-- common:end -->'; do
		grep -qF "$marker" "$target" || {
			echo "gen.sh: $target has no $marker marker" >&2
			exit 1
		}
	done
	{
		sed -n '1,/<!-- common:start -->/p' "$target"
		cat "$here/COMMON.md"
		sed -n '/<!-- common:end -->/,$p' "$target"
	} >"$target.new"
	mv "$target.new" "$target"
done
