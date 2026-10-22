#!/bin/sh
# Table-driven test for guard-apply.sh: sh plugin/hooks/guard-apply_test.sh
here=$(cd "$(dirname "$0")" && pwd)
failed=0

# check ask|allow 'command string'
check() {
	want=$1 command=$2
	escaped=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g')
	out=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$escaped" | sh "$here/guard-apply.sh")
	case $out in *'"ask"'*) got=ask ;; *) got=allow ;; esac
	if [ "$got" != "$want" ]; then
		printf 'FAIL want %s got %s: %s\n' "$want" "$got" "$command"
		failed=1
	fi
}

# Plain reads and plans pass.
check allow 'ls -la'
check allow 'zc-care plan -json -target brew -out plan.json'
check allow 'zc-care status -json'
check allow 'cat zc-care.yaml'
check allow 'zc-care doctor -json'
check allow 'zc-care apply plan.json'
check allow 'zc-care apply -target brew plan.json'
check allow 'zc-care apply -config ~/zc-care.yaml -only brew:jq plan.json'
check allow 'zc-care apply "plan.json"'
check allow 'zc-care plan -out plan.json && zc-care apply plan.json'

# Apply without a reviewed plan file.
check ask 'zc-care apply'
check ask 'zc-care apply -target brew'
check ask 'zc-care apply -only plan.json'
check ask 'zc-care apply -via an-agent'
check ask 'zc-care apply -out plan.json'
check ask 'zc-care apply -remove cask:foo'

# -yes on any subcommand.
check ask 'zc-care apply -yes plan.json'
check ask 'zc-care apply plan.json --yes'
check ask 'zc-care undo -yes'
check ask 'zc-care upgrade -yes'
check ask 'zc-care doctor -fix -yes'

# remove.
check ask 'zc-care remove -target packages brew:htop'

# Input fed to the command.
check ask 'yes | zc-care apply plan.json'
check ask 'echo yes | zc-care apply plan.json'
check ask 'printf "y\n" | zc-care undo'
check ask 'zc-care apply plan.json <<< yes'
check ask 'zc-care undo <<EOF'

# Indirect invocations.
check ask 'Z=zc-care; $Z apply'
check ask '${Z} apply -yes plan.json'
check ask "sh -c 'zc-care apply'"
check ask "sh -c 'zc-care apply -yes plan.json'"
check ask 'command zc-care remove brew:jq'
check ask 'env X=y zc-care apply'
check ask 'cd ~ && /opt/homebrew/bin/zc-care apply'
check allow 'env X=y zc-care apply plan.json'

[ "$failed" = 0 ] && echo "guard-apply: all cases pass"
exit "$failed"
