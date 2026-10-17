#!/usr/bin/env bash
#
# run-and-pr.sh
#
# Run scripts/vsql-test.sh from a checkout of this repo, then commit the logs
# to a new branch and open a pull request so every run is kept in history.
#
# Usage (from the repo root):
#   GH_TOKEN=... ./scripts/run-and-pr.sh [sql-file] [codebase ...]
#
#   sql-file  defaults to sql/smoke.sql
#   codebase  defaults to all three (mysql-8.4 percona-8.4 mysql-9.7)
#
# Environment:
#   GH_TOKEN        Token with contents:write and pull-requests:write on this repo
#   BASE_BRANCH     Branch the PR targets (default: main)
#   AUTO_MERGE=1    Squash-merge the PR straight away (logs are append-only)
#   DRY_RUN=1       Run the tests and commit locally, but do not push or open a PR
#   RUN_SOURCE      Free text recorded in the PR body (e.g. "cloudflare cron")
#
# Exit status: the exit status of vsql-test.sh (0 = all variants passed).
# A failing test still produces a PR, so failures are recorded too.

set -uo pipefail

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 2; }

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "Run this from inside the vsql repo."
cd "$REPO_ROOT" || exit 2

SQL_FILE="${1:-sql/smoke.sql}"
[ $# -gt 0 ] && shift
BASE_BRANCH="${BASE_BRANCH:-main}"

if [ "${DRY_RUN:-0}" != "1" ]; then
  [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is not set."
  command -v gh >/dev/null 2>&1 || die "'gh' is required to open the pull request."
  export GH_TOKEN
  gh auth setup-git >/dev/null 2>&1 || true
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DAY=$(date -u +%Y/%m/%d)
LOG_DIR="logs/$DAY/$STAMP"
BRANCH="test-log/$STAMP"

git fetch --quiet origin "$BASE_BRANCH" 2>/dev/null || true
git checkout --quiet -B "$BRANCH" "origin/$BASE_BRANCH" 2>/dev/null \
  || git checkout --quiet -B "$BRANCH"

log "Running tests; logs go to $LOG_DIR"
VSQL_LOG_DIR="$LOG_DIR" ./scripts/vsql-test.sh "$SQL_FILE" "$@" 2>&1 | tee "$STAMP.console.log"
TEST_RC=${PIPESTATUS[0]}
mkdir -p "$LOG_DIR"
mv "$STAMP.console.log" "$LOG_DIR/console.log"

RESULT=$(jq -r '.result // "FAIL"' "$LOG_DIR/summary.json" 2>/dev/null || echo "FAIL")
[ "$TEST_RC" -eq 0 ] || RESULT="FAIL"
TITLE="VillageSQL test $STAMP: $RESULT ($(basename "$SQL_FILE"))"

git config user.name  >/dev/null || git config user.name  "vsql-test-runner"
git config user.email >/dev/null || git config user.email "vsql-test-runner@users.noreply.github.com"
git add "$LOG_DIR"
git commit --quiet -m "$TITLE" -m "Logs: $LOG_DIR" || die "Nothing to commit."
log "Committed $LOG_DIR on $BRANCH"

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN=1: not pushing or opening a PR."
  exit "$TEST_RC"
fi

BODY_FILE=$(mktemp)
{
  echo "Automated VillageSQL prebuilt test run."
  echo
  echo "- Result: **$RESULT**"
  echo "- SQL script: \`$SQL_FILE\`"
  echo "- Logs: \`$LOG_DIR\`"
  echo "- Source: ${RUN_SOURCE:-manual} on $(uname -srm)"
  echo
  cat "$LOG_DIR/summary.md" 2>/dev/null || echo "_No summary produced; see console.log._"
} > "$BODY_FILE"

git push --quiet -u origin "$BRANCH" || die "Push failed."
PR_URL=$(gh pr create --base "$BASE_BRANCH" --head "$BRANCH" \
           --title "$TITLE" --body-file "$BODY_FILE") || die "Could not open the PR."
rm -f "$BODY_FILE"
log "Opened $PR_URL"

if [ "${AUTO_MERGE:-0}" = "1" ]; then
  gh pr merge "$PR_URL" --squash --delete-branch && log "Merged $PR_URL"
fi

exit "$TEST_RC"
