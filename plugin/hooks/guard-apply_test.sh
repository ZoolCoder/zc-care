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

# Plain reads and read-only subcommands pass.
check allow 'ls -la'
check allow 'git log'
check allow 'make build'
check allow 'zc-care'
check allow 'zc-care plan -json -target brew -out plan.json'
check allow 'zc-care status -json'
check allow 'cat zc-care.yaml'
check allow 'cd ~/Developer/Tools/zc-care && make build'
check allow 'zc-care doctor -json'
check allow 'zc-care -config ~/zc-care.yaml list -json 2>&1'
check allow 'ZC_CARE_CONFIG=x.yaml zc-care plan'
check allow 'zc-care history -n 5 | head'
check allow 'zc-care drift -json'
check allow 'zc-care capture -target brew'
check allow 'zc-care export -o snap.json'
check allow 'zc-care diff a.json b.json'
check allow 'zc-care validate'
check allow 'zc-care version'
check allow 'zc-care help'
check allow 'zc-care plan > out.json'
check allow 'printf x | tee $LOG'
check allow 'echo $HOME'

# apply always asks, with or without a plan file, and whatever follows it.
check ask 'zc-care apply'
check ask 'zc-care apply plan.json'
check ask 'zc-care apply -target brew plan.json'
check ask 'zc-care apply -config ~/zc-care.yaml -only brew:jq plan.json'
check ask 'zc-care apply "plan.json"'
check ask 'zc-care plan -out plan.json && zc-care apply plan.json'
check ask 'zc-care apply -target brew'
check ask 'zc-care apply -only plan.json'
check ask 'zc-care apply -via an-agent'
check ask 'zc-care apply -out plan.json'
check ask 'zc-care apply -remove cask:foo'
check ask 'zc-care apply > out.json'
check ask 'zc-care apply 2> err.json'
check ask 'zc-care apply -state x.json'

# -yes / -y anywhere.
check ask 'zc-care apply -yes plan.json'
check ask 'zc-care apply plan.json --yes'
check ask 'zc-care plan -yes'
check ask 'zc-care plan -y'
check ask 'zc-care undo -yes'
check ask 'zc-care upgrade -yes'
check ask 'zc-care doctor -fix -yes'

# State-changing or unlisted subcommands.
check ask 'zc-care doctor -fix'
check ask 'zc-care drift -fix'
check ask 'zc-care undo'
check ask 'zc-care undo -json'
check ask 'zc-care upgrade'
check ask 'zc-care remove -target packages brew:htop'
check ask 'zc-care init -profile dev'
check ask 'zc-care add -target brew brew:jq'
check ask 'zc-care skip brew:jq'
check ask 'zc-care profile dev'
check ask 'zc-care mcp'
check ask 'zc-care frobnicate'

# Input fed to the command.
check ask 'yes | zc-care apply plan.json'
check ask 'echo yes | zc-care apply plan.json'
check ask 'printf "y\n" | zc-care undo'
check ask 'zc-care apply plan.json <<< yes'
check ask 'zc-care undo <<EOF'

# Shell tricks the guard cannot expand.
check ask 'zc-care ap"ply"'
check ask "zc-care a'p'ply"
check ask 'zc-care $(echo apply)'
check ask 'a=apply; zc-care $a'
check ask 'zc-care apply$IFS-yes'
check ask '$(which zc-care) apply'
check ask '`which zc-care` apply'
check ask '"$(command -v zc-care)" apply'
check ask 'alias z=zc-care; z apply'
check ask 'alias z=zc-care && z apply'
check ask 'ln -s /opt/homebrew/bin/zc-care z && z apply'
check ask 'zc-"care" apply'
check ask 'zc-ca\re apply'
check ask 'zc-care plan; zc-care apply'
check ask 'Z=zc-care; $Z apply'
check ask '${Z} apply -yes plan.json'
check ask "sh -c 'zc-care apply'"
check ask "sh -c 'zc-care plan'"
check ask 'command zc-care remove brew:jq'
check ask 'env X=y zc-care plan'
check ask 'cd ~ && /opt/homebrew/bin/zc-care apply'
check ask 'which zc-care'
check ask 'echo hi | grep zc-care'
check ask 'zc-care plan -config "my dir/zc-care.yaml"'

# A bare variable as the command with a risky word keeps the old protection.
check ask '$ZC apply'
check ask '$ZC plan -yes'
check ask '"$ZC" apply'
check ask 'echo y | $ZC undo'
check allow '$ZC plan'
check allow 'echo y | tee $LOG'

[ "$failed" = 0 ] && echo "guard-apply: all cases pass"
exit "$failed"
