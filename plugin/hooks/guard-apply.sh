#!/bin/sh
# PreToolUse guard: asks the user before a Bash call can run zc-care in a way
# nobody reviewed. It sees only the command string and never expands the shell,
# so it fails closed:
#   - a command that names zc-care is read only when it is a plain pipeline of
#     simple words (no quotes, $, `, (), {}, ;, backslash) whose zc-care
#     segment starts with zc-care and a read-only subcommand: plan, status,
#     list, history, drift, capture, diff, validate, doctor, version, help, or
#     none. Everything else asks: apply (even with a plan file), undo, upgrade,
#     remove, init, add, skip, profile, mcp, export (it writes a file), any
#     other word, -yes, -y, -fix.
#   - whatever the text says, these ask: eval; a pipe, here-doc, here-string or
#     process substitution into sh, bash, zsh, dash, ksh, python, perl, ruby,
#     node or osascript; a command word that starts with $ or a backtick or
#     holds \x, \0 or $'; a base64/xxd/rev decode next to something that runs.
#   - a command that mentions "zc" in any case also asks when it uses a
#     launcher or disguise that can hide the name: a glob in a command word,
#     find -exec, xargs, git -c alias., env, exec, nohup, time, command,
#     builtin, sh -c, nice, caffeinate, script.
#   - anything else passes: the guard must stay quiet on ordinary commands.
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

# The one flag that may come before the subcommand and take a value. Any other
# word that is not a flag is the subcommand, so a flag's value cannot hide it.
takes_value() {
	case $1 in
	-config | --config) return 0 ;;
	esac
	return 1
}

check_invocation() {
	skip=0 sub=""
	for word; do
		is_risky_word "$word" && ask "zc-care $word changes this Mac or confirms for a person; use the MCP plan and apply tools, or run it in a terminal."
		if [ "$skip" = 1 ]; then
			skip=0
		elif [ -z "$sub" ] && takes_value "$word"; then
			skip=1
		else
			case $word in -*) ;; *) [ -n "$sub" ] || sub=$word ;; esac
		fi
	done
	case $sub in
	"" | plan | status | list | history | drift | capture | diff | validate | doctor | version | help) ;;
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

each_segment() {
	handler=$1
	while IFS= read -r line; do
		# shellcheck disable=SC2086
		$handler $line
	done <<EOF
$2
EOF
}

# Commands that run what they are fed, or whose name is not the real name.
interpreters='(sh|bash|zsh|dash|ksh|python[0-9.]*|perl|ruby|node|osascript)'
launchers='(xargs|env|exec|nohup|time|command|builtin|nice|caffeinate|script)'

mentions() {
	printf '%s' "$cmd" | grep -Eq "(^|[^A-Za-z0-9_.-])$1(\$|[^A-Za-z0-9_.-])"
}

# The command word of a segment, after any NAME=value prefixes.
command_word() {
	for word; do
		case $word in [A-Za-z_]*=*) ;; *) printf '%s' "$word"; return ;; esac
	done
}

# A glob in a command word is noted: with "zc" in the text it may spell zc-care.
check_command_word() {
	word=$(command_word "$@")
	[ -n "$word" ] || return 0
	case $word in
	*\$\'* | *\\x* | *\\0*) ask "A command name is spelled with escapes the guard cannot read." ;;
	esac
	bare=$(printf '%s' "$word" | tr -d '\047\042')
	case $bare in
	\$* | \`*) ask "The command itself is a variable or substitution; it may be zc-care." ;;
	eval) ask "eval runs text the guard cannot read." ;;
	'[' | '[[') ;;
	*[*?[]*) glob=1 ;;
	esac
}

check_text() {
	if printf '%s' "$cmd" | grep -Eq "(^|[^|])\|[[:space:]]*((sudo|env|exec|nohup|command)[[:space:]]+)*([A-Za-z0-9_./-]*/)?$interpreters([[:space:]]|\$)"; then
		ask "Output is piped into a shell or interpreter, which runs text the guard cannot read."
	fi
	if printf '%s' "$cmd" | grep -Eq "(^|[^A-Za-z0-9_./-])$interpreters([[:space:]][^|;&]*)?(<<|<\()"; then
		ask "A here-doc, here-string or process substitution feeds a shell or interpreter."
	fi
	if printf '%s' "$cmd" | grep -Eq 'base64[[:space:]]+(-[dD]|--decode)|xxd[[:space:]]+-[A-Za-z]*r|(^|[^A-Za-z0-9_.-])rev($|[^A-Za-z0-9_.-])' &&
		{ mentions "$interpreters" || mentions "(xargs|eval|exec|source)" || printf '%s' "$cmd" | grep -Eq '\$\(|`'; }; then
		ask "Decoded text sits next to something that runs it."
	fi
}

# "zc" in any case and a way to hide the name.
check_disguise() {
	printf '%s' "$cmd" | grep -qi 'zc' || return 0
	[ "$glob" = 1 ] && ask "A glob in a command word can spell zc-care."
	mentions "$launchers" && ask "A launcher in a command that mentions zc may run zc-care."
	printf '%s' "$cmd" | grep -Eq 'find[[:space:]].*-(exec|execdir|ok|okdir)([[:space:]]|$)' && ask "find -exec in a command that mentions zc may run zc-care."
	printf '%s' "$cmd" | grep -Eq 'git[[:space:]].*-c[[:space:]]*alias\.' && ask "A git alias in a command that mentions zc may run zc-care."
	printf '%s' "$cmd" | grep -Eq "(^|[^A-Za-z0-9_.-])(sh|bash|zsh)[[:space:]]+-[A-Za-z]*c" && ask "A shell -c in a command that mentions zc may run zc-care."
	return 0
}

# Redirections removed, then one line per simple command.
segments=$(printf '%s' "$cmd" |
	sed -E 's/[0-9]*>&[0-9-]*/ /g; s/[0-9]*[<>]+/ /g' | tr ';&|' '\n\n\n' | sed -E 's/^[[:space:](){!]+//')

check_text
glob=0
each_segment check_command_word "$segments"
check_disguise

# Quotes and backslashes removed, so zc-"care" and zc-ca\re still count as named.
flat=$(printf '%s' "$cmd" | tr -d '\047\042\134')

if printf '%s' "$flat" | grep -Eq '(^|[^A-Za-z0-9_.-])zc-care($|[^A-Za-z0-9_./-])'; then
	if printf '%s' "$cmd" | grep -q '[^A-Za-z0-9_./=:@,+~&|<> -]'; then
		ask "A command naming zc-care uses quotes, \$, backticks, parentheses, braces, ; or a backslash, which the guard cannot read. Use plain words, or the MCP tools."
	fi
	each_segment check_segment "$(printf '%s' "$cmd" |
		sed -E 's/[0-9]*>&[0-9-]*/ /g; s/[0-9]*[<>]+/ /g' | tr '&|' '\n\n')"
fi
exit 0
