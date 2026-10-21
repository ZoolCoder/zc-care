#!/bin/sh
# PreToolUse guard: asks the user before a Bash call runs `zc-care remove`, or
# `zc-care apply` with -yes or without a saved plan file. It never blocks on
# its own; the user decides.
input=$(cat)

reason=""
if printf '%s' "$input" | grep -Eq 'zc-care[^|;&]*[[:space:]]remove([[:space:]]|"|$)'; then
	reason="zc-care remove uninstalls software and drops it from the manifest."
	printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$reason"
	exit 0
fi

printf '%s' "$input" | grep -Eq 'zc-care[^|;&]*[[:space:]]apply([[:space:]]|"|$)' || exit 0

if printf '%s' "$input" | grep -Eq '[[:space:]]-{1,2}yes([=[:space:]]|"|$)'; then
	reason="zc-care apply with -yes deletes without a prompt."
else
	# What follows apply, with value flags and their values dropped: a saved
	# plan file is the one word left.
	rest=$(printf '%s' "$input" | sed -nE 's/.*zc-care[^|;&]*[[:space:]]apply([^|;&"]*).*/\1/p' |
		sed -E 's/-{1,2}(target|config)(=|[[:space:]]+)[^[:space:]]+//g; s/-{1,2}[a-z-]+//g')
	if ! printf '%s' "$rest" | grep -Eq '[^[:space:]]'; then
		reason="zc-care apply without a saved plan file applies whatever the live state is now, not a plan the user reviewed."
	fi
fi
[ -n "$reason" ] || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$reason"
