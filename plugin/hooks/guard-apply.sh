#!/bin/sh
# PreToolUse guard: asks the user before a Bash call can apply or uninstall
# without a person confirming. It sees only the command string, so it reads
# every zc-care invocation in it (also behind $VAR, `sh -c`, `command`, `env`)
# and asks when it finds one of these:
#   - `-yes` on any subcommand
#   - `remove`
#   - `apply` without a saved plan file (a .json or .plan argument)
#   - input fed to zc-care: `yes | zc-care ...`, `echo y | ...`, `<<<`, `<<`
# It never blocks; the user decides. Tested by guard-apply_test.sh.
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
	sed -e 's/\\n/ ; /g; s/\\t/ /g; s/\\"/"/g; s/\\u0026/\&/g; s/\\u003c/</g; s/\\u003e/>/g; s/\\u0027/'"'"'/g')

invoker='(zc-care|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]*\})'

printf '%s' "$cmd" | grep -Eq 'zc-care|\$' || exit 0

# Input fed to a zc-care command answers its prompts for the user.
feeders="(^|[^[:alnum:]_.-])(yes|echo|printf)([[:space:]][^|]*)?\\|[[:space:]]*[^;&|]*$invoker"
if printf '%s' "$cmd" | grep -Eq "$feeders" ||
	printf '%s' "$cmd" | grep -Eq "zc-care[^;&|]*<<"; then
	ask "Input is piped or redirected into zc-care, which answers its confirmation prompt for the user."
fi

# Value flags: the word after one is a value, never a plan file or subcommand.
read_invocation() {
	set -f
	# shellcheck disable=SC2086
	set -- $1
	sub="" skip=0 yes=0 planfile=0
	for word; do
		word=${word#[\"\']}
		word=${word%[\"\']}
		if [ "$skip" = 1 ]; then
			skip=0
			continue
		fi
		case $word in
		-yes | --yes | -yes=* | --yes=*) yes=1 ;;
		-target | --target | -config | --config | -only | --only | -remove | --remove | -out | --out | -via | --via | -n | --n | -id | --id) skip=1 ;;
		-*) ;;
		*)
			if [ -z "$sub" ]; then
				sub=$word
			else
				case $word in *.json | *.plan) planfile=1 ;; esac
			fi
			;;
		esac
	done
}

# Each invocation: its words up to the next separator.
invocations=$(printf '%s' "$cmd" |
	grep -oE "$invoker[[:space:]]+[^;&|\`)]*" | sed -E "s/^$invoker[[:space:]]+//")
oldIFS=$IFS
IFS='
'
for invocation in $invocations; do
	IFS=$oldIFS
	read_invocation "$invocation"
	[ "$yes" = 1 ] && ask "zc-care -yes confirms without asking a person."
	case $sub in
	remove) ask "zc-care remove uninstalls software and drops it from the manifest." ;;
	apply)
		[ "$planfile" = 1 ] ||
			ask "zc-care apply without a saved plan file applies whatever the live state is now, not a plan the user reviewed."
		;;
	esac
	IFS='
'
done
exit 0
