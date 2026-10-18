#!/usr/bin/env bash
# Stamps the tool's identity onto a copy of go-tool-template: module path,
# binary and command directory, env prefix, URLs. Idempotent, so Copier runs
# it on every copy and on both sides of an update.
#
#   scripts/init.sh <tool-name> [--org ZoolCoder]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: init.sh <tool-name> [--org ZoolCoder]}"
shift
ORG="ZoolCoder"
while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
[[ "$APP" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] || { echo "tool name must be kebab-case: $APP" >&2; exit 1; }

OLD="go-tool-template"
OLD_ENV="GO_TOOL_TEMPLATE"
ORG_LC="$(echo "$ORG" | tr '[:upper:]' '[:lower:]')"
ENV="$(echo "$APP" | tr '[:lower:]-' '[:upper:]_')"

sed_inplace() { sed -i '' "$@" 2>/dev/null || sed -i "$@"; }

[ "$APP" = "$OLD" ] && [ "$ORG_LC" = zoolcoder ] && { echo "==> $OLD: nothing to rename"; exit 0; }

echo "==> Renaming $OLD to $APP (github.com/$ORG_LC/$APP, \$${ENV}_CONFIG)"
grep -rlI --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=build --exclude-dir=bin \
  --exclude=init.sh -e "$OLD" -e "$OLD_ENV" . |
  while read -r f; do
    sed_inplace \
      -e "s|ZoolCoder/$OLD|$ORG/$APP|g" \
      -e "s|zoolcoder/$OLD|$ORG_LC/$APP|g" \
      -e "s|zoolcoder\.github\.io/$OLD|$ORG_LC.github.io/$APP|g" \
      -e "s|$OLD|$APP|g" \
      -e "s|$OLD_ENV|$ENV|g" "$f"
  done || true

for path in "cmd/$OLD" "plugin/adapters/cursor/$OLD.mdc" "$OLD.example.yaml"; do
  [ -e "$path" ] && mv "$path" "${path//$OLD/$APP}"
done

# The README's notes on using the template do not belong to the tool.
[ -f README.md ] && sed_inplace '/<!-- template:start -->/,/<!-- template:end -->/d' README.md
echo "==> done"
