#!/bin/sh
# PreToolUse guard: asks the user before a Bash call can run zc-care in a way
# nobody reviewed. It sees only the command string and never expands the shell,
# so it fails closed:
#   - a command that names zc-care is read only when it is a plain pipeline of
#     simple words (no quotes, $, `, (), {}, ;, backslash) whose zc-care
#     segment starts with zc-care and a read-only subcommand: plan, status,
#     list, history, drift, capture, export, diff, validate, doctor, version,
#     help, or none. Everything else asks: apply (even with a plan file),
#     undo, upgrade, remove, init, add, skip, profile, mcp, -yes, -y, -fix.
#   - a command that does not name zc-care asks only when a pipeline segment
#     starts with a $VAR or `...` and carries one of those words.
# The reviewed path for agents is the MCP apply tool. The guard never blocks;
# the user decides. Tested by guard-apply_test.sh.
set -f
input=$(cat)

ask() {
	printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
	exit 0
}

# The command string, unescaped from its JSON; newlines act as separators.
cmd=$(printf '%s' "$input" |
	sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
[ -n "$cmd" ] || cmd=$input
cmd=$(printf '%s' "$cmd" |
	sed -e 's/\\n/ \&\& /g; s/\\t/ /g; s/\\"/"/g; s/\\u0026/\&/g; s/\\u003c/</g; s/\\u003e/>/g; s/\\u0027/'"'"'/g')

# Words that change state or answer a prompt, wherever they stand.
is_risky_word() {
	case $1 in
	apply | undo | remove | init | upgrade | add | mcp | skip | profile) return 0 ;;
	-yes | --yes | -y | --y | -yes=* | --yes=* | -y=* | --y=*) return 0 ;;
	-fix | --fix | -fix=* | --fix=*) return 0 ;;
	esac
	return 1
}

is_zc_word() {
	case $1 in zc-care | */zc-care) return 0 ;; esac
	return 1
}

# Flags whose next word is their value, never a subcommand.
takes_value() {
	case $1 in
	-config | --config | -target | --target | -only | --only | -remove | --remove | -out | --out | -o | -state | -kind | -data | -n | -id | -via | -hour | -profile | -role | -dir | -why | -section) return 0 ;;
	esac
	return 1
}

check_invocation() {
	skip=0 sub=""
	for word; do
		is_risky_word "$word" && ask "zc-care $word changes this Mac or confirms for a person; use the MCP plan and apply tools, or run it in a terminal."
		if [ "$skip" = 1 ]; then
			skip=0
		elif takes_value "$word"; then
			skip=1
		else
			case $word in -*) ;; *) [ -n "$sub" ] || sub=$word ;; esac
		fi
	done
	case $sub in
	"" | plan | status | list | history | drift | capture | export | diff | validate | doctor | version | help) ;;
	*) ask "zc-care $sub is not on the read-only list." ;;
	esac
}

check_segment() {
	[ $# -gt 0 ] || return 0
	[ "$1" = cd ] && return 0
	mentions=0
	for word; do
		case $word in *zc-care) mentions=1 ;; esac
	done
	[ "$mentions" = 1 ] || return 0
	while :; do
		case $1 in [A-Za-z_]*=*zc-care) break ;; [A-Za-z_]*=*) shift ;; *) break ;; esac
		[ $# -gt 0 ] || return 0
	done
	is_zc_word "$1" || ask "zc-care is named in a command the guard cannot read as a plain zc-care call."
	shift
	check_invocation "$@"
}

# A $VAR or `...` as the command may be zc-care: ask when it carries a risky word.
check_variable_segment() {
	[ $# -gt 0 ] || return 0
	case $1 in \$* | \`*) ;; *) return 0 ;; esac
	shift
	for word; do
		is_risky_word "$word" && ask "A variable or substitution runs a command with $word; it may be zc-care."
		case $word in *\$* | *\`*) ask "A variable or substitution runs a command with another substitution." ;; esac
	done
}

each_segment() {
	handler=$1
	while IFS= read -r line; do
		# shellcheck disable=SC2086
		$handler $line
	done <<EOF
$2
EOF
}

# Quotes and backslashes removed, so zc-"care" and zc-ca\re still count as named.
flat=$(printf '%s' "$cmd" | tr -d '\047\042\134')

if printf '%s' "$flat" | grep -Eq '(^|[^A-Za-z0-9_.-])zc-care($|[^A-Za-z0-9_./-])'; then
	if printf '%s' "$cmd" | grep -q '[^A-Za-z0-9_./=:@,+~&|<> -]'; then
		ask "A command naming zc-care uses quotes, \$, backticks, parentheses, braces, ; or a backslash, which the guard cannot read. Use plain words, or the MCP tools."
	fi
	segments=$(printf '%s' "$cmd" |
		sed -E 's/[0-9]*>&[0-9-]*/ /g; s/[0-9]*[<>]+/ /g' | tr '&|' '\n\n')
	each_segment check_segment "$segments"
	exit 0
fi

segments=$(printf '%s' "$flat" | tr '(){}' '    ' | tr ';&|' '\n\n\n')
each_segment check_variable_segment "$segments"
exit 0
