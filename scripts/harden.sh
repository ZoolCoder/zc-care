#!/usr/bin/env bash
# Puts the GitHub repository's settings where GOVERNANCE.md and SECURITY.md say
# they are: git flow with develop as the default branch, the rulesets, and the
# security features. Safe to run again. Needs gh, signed in with admin rights.
#
#   scripts/harden.sh [owner/repo]   (default: the repository gh sees here)
set -euo pipefail

repo=${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}

# git flow needs develop before it can be the default branch.
if ! gh api "repos/$repo/branches/develop" >/dev/null 2>&1; then
	sha=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)
	gh api -X POST "repos/$repo/git/refs" -f ref=refs/heads/develop -f sha="$sha" >/dev/null
	echo "created  develop from main"
fi

# The wiki is off because the manual is the documentation; a second place drifts.
gh api -X PATCH "repos/$repo" \
	-f default_branch=develop \
	-F delete_branch_on_merge=true \
	-F allow_update_branch=true \
	-F has_wiki=false \
	-f 'security_and_analysis[secret_scanning][status]=enabled' \
	-f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
	-f 'security_and_analysis[secret_scanning_non_provider_patterns][status]=enabled' \
	-f 'security_and_analysis[secret_scanning_validity_checks][status]=enabled' >/dev/null
echo "set      default branch develop, delete merged branches, wiki off, secret scanning"

gh api -X PUT "repos/$repo/vulnerability-alerts" >/dev/null
gh api -X PUT "repos/$repo/automated-security-fixes" >/dev/null
gh api -X PUT "repos/$repo/private-vulnerability-reporting" >/dev/null
echo "enabled  Dependabot alerts, security updates, private vulnerability reporting"

# The workflow token is read-only unless a job asks for more. Actions may open
# pull requests, because the release workflow opens the cask's; GitHub ties that
# to approving them. Merging still needs a pull request with green checks.
gh api -X PUT "repos/$repo/actions/permissions/workflow" \
	-f default_workflow_permissions=read -F can_approve_pull_request_reviews=true >/dev/null
echo "set      workflow token read-only, Actions may open pull requests"

# The manual deploys from main, but Pages lets only the default branch deploy.
gh api -X PUT "repos/$repo/environments/github-pages" \
	-F 'deployment_branch_policy[protected_branches]=false' \
	-F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null
gh api -X POST "repos/$repo/environments/github-pages/deployment-branch-policies" \
	-f name=main -f type=branch >/dev/null 2>&1 || true
echo "allowed  main to deploy the manual to Pages"
"$(dirname "$0")/rulesets.sh" "$repo"
