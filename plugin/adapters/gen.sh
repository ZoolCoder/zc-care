#!/bin/sh
# Copies COMMON.md into every adapter, between its <!-- common:start --> and
# <!-- common:end --> markers. Edit COMMON.md, run `sh plugin/adapters/gen.sh`.
# TestAdaptersCarryCommon fails when a copy drifts.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
for file in cloud/AGENTS.md codex/AGENTS.md copilot/copilot-instructions.md cursor/zc-care.mdc gemini/GEMINI.md; do
	target=$here/$file
	trap 'rm -f "$target.new"' EXIT
	# Exactly one of each marker, start first: a second copy or a swapped pair
	# would make the sed ranges below drop or double the file's own text.
	for marker in '<!-- common:start -->' '<!-- common:end -->'; do
		[ "$(grep -cF "$marker" "$target")" = 1 ] || {
			echo "gen.sh: $target needs exactly one $marker marker" >&2
			exit 1
		}
	done
	start=$(grep -nF '<!-- common:start -->' "$target" | cut -d: -f1)
	end=$(grep -nF '<!-- common:end -->' "$target" | cut -d: -f1)
	[ "$start" -lt "$end" ] || {
		echo "gen.sh: $target has its end marker before its start marker" >&2
		exit 1
	}
	{
		sed -n '1,/<!-- common:start -->/p' "$target"
		cat "$here/COMMON.md"
		sed -n '/<!-- common:end -->/,$p' "$target"
	} >"$target.new"
	mv "$target.new" "$target"
done
