#!/usr/bin/env bash
# Applies .github/rulesets/*.json to the GitHub repository: creates a ruleset
# that does not exist yet, updates one with the same name. Needs gh, signed in
# with admin rights on the repository.
#
#   scripts/rulesets.sh [owner/repo]   (default: the repository gh sees here)
set -euo pipefail

repo=${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
dir=$(cd "$(dirname "$0")/../.github/rulesets" && pwd)

for file in "$dir"/*.json; do
	name=$(jq -r .name "$file")
	id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id")
	if [ -n "$id" ]; then
		gh api -X PUT "repos/$repo/rulesets/$id" --input "$file" >/dev/null
		echo "updated  $name"
	else
		gh api -X POST "repos/$repo/rulesets" --input "$file" >/dev/null
		echo "created  $name"
	fi
done
