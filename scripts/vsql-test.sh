#!/usr/bin/env bash
#
# vsql-test.sh
#
# Install VillageSQL prebuilt binaries with the official installer
# (https://install.villagesql.com) for one or more server codebases, start
# each one, run a SQL script against it, and record the results.
#
# Usage:
#   ./scripts/vsql-test.sh <sql-file> [codebase ...]
#
#   codebase: mysql-8.4 | percona-8.4 | mysql-9.7   (default: all three)
#
# Environment overrides:
#   VSQL_LOG_DIR       Where to write per-variant logs and summary files
#                      (default: ./logs/<UTC timestamp>)
#   VSQL_WORKDIR       Scratch directory for installs (default: /tmp/vsql)
#   VSQL_BASE_PORT     First TCP port; each variant gets the next one (default: 13306)
#   VSQL_DATABASE      Database created and selected before the script (default: vsql_test)
#   VSQL_FORCE=1       Continue past SQL errors (mysql --force)
#   VSQL_INSTALLER_URL Override the installer location (default: install.villagesql.com)
#   VSQL_TELEMETRY=1   Allow the installer's anonymous install telemetry
#                      (default: opted out via an empty ~/.villagesql/.install_id)
#
# Notes:
#   - The installer offers prebuilt binaries for the STABLE release only.
#   - The installer refuses to run as root; run this as a regular user.
#   - The installer always uses $HOME/.villagesql, so each variant gets its own HOME.
#
# Exit status: 0 only if every requested variant installed, started and ran
# the SQL script without errors.

set -uo pipefail

INSTALLER_URL="${VSQL_INSTALLER_URL:-https://install.villagesql.com}"
ALL_CODEBASES=(mysql-8.4 percona-8.4 mysql-9.7)

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 2; }

usage() {
  sed -n '3,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[ $# -ge 1 ] || usage 2
case "$1" in -h|--help) usage 0 ;; esac

SQL_FILE=$(realpath "$1") || die "SQL file not found: $1"
[ -s "$SQL_FILE" ] || die "SQL file is empty or missing: $1"
shift
if [ $# -gt 0 ]; then CODEBASES=("$@"); else CODEBASES=("${ALL_CODEBASES[@]}"); fi
for cb in "${CODEBASES[@]}"; do
  case "$cb" in mysql-8.4|percona-8.4|mysql-9.7) ;; *) die "Unknown codebase: $cb" ;; esac
done

[ "$(id -u)" -ne 0 ] || die "Run as a regular user; the VillageSQL installer refuses root."
for cmd in curl tar jq realpath; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
done

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG_DIR="${VSQL_LOG_DIR:-$PWD/logs/$STAMP}"
WORKDIR="${VSQL_WORKDIR:-/tmp/vsql}"
BASE_PORT="${VSQL_BASE_PORT:-13306}"
DATABASE="${VSQL_DATABASE:-vsql_test}"
mkdir -p "$LOG_DIR" "$WORKDIR"
LOG_DIR=$(realpath "$LOG_DIR")

log "Fetching installer from $INSTALLER_URL"
_T=$(date +%s)
INSTALLER="$WORKDIR/install.sh"
curl -fsSL "$INSTALLER_URL" -o "$INSTALLER" || { stage_post "-" download 1 $(( $(date +%s) - _T )); die "Could not download the installer."; }
DL_ELAPSED=$(( $(date +%s) - _T ))
INSTALLER_SHA=$(sha256sum "$INSTALLER" | cut -c1-12)
SQL_SHA=$(sha256sum "$SQL_FILE" | cut -c1-12)
cp "$INSTALLER" "$LOG_DIR/install.sh"
# The installer sleeps a fixed 2s after shutting down its temporary server and
# then restarts it; on slower disks/containers the old server still holds the
# InnoDB lock. Wait (up to 120s) for the pid file to disappear instead.
sed -i 's|^\( *\)sleep 2$|\1for _i in $(seq 1 120); do [ -e "${INSTALL_BASE}/mysql.pid" ] \|\| break; sleep 1; done; sleep 1|' "$INSTALLER"
cp "$SQL_FILE" "$LOG_DIR/test.sql"
log "Installer sha256 $INSTALLER_SHA, SQL script sha256 $SQL_SHA"

# Optional, non-fatal Slack post; skipped when run-and-pr.sh already reports.
# shellcheck source=scripts/slack-lib.sh
. "$(dirname "$0")/slack-lib.sh"
if [ -n "${SLACK_FROM_PARENT:-}" ]; then slack() { :; }; fi

# Remove a secret from a log file in place.
redact() { [ -n "$2" ] && [ -f "$1" ] && sed -i "s/$2/[REDACTED]/g" "$1"; return 0; }


# ---- Stage-level Slack debugging (always non-fatal, secrets stripped) ----
dslack() {
  [ -n "${SLACK_BOT_TOKEN:-}" ] || return 0
  SLACK_PREFIX="$(slack_prefix 2>/dev/null)" "$(dirname "$0")/slack-post" "$*" >/dev/null 2>&1 || true
}
scrub() {
  sed -E -e 's/xox[a-z]-[A-Za-z0-9-]+/[REDACTED]/g' \
         -e 's/(ghp|gho|ghs|ghu|github_pat)_[A-Za-z0-9_]+/[REDACTED]/g' \
         -e 's/([Pp]assword:? *)[^ ]+/\1[REDACTED]/g' \
         -e 's/(Bearer|RUN_KEY|TOKEN|SECRET)[=: ]+[^ ]+/\1=[REDACTED]/g' \
    ${PASSWORD:+-e "s/$PASSWORD/[REDACTED]/g"} 2>/dev/null | cut -c1-300
}
# stage_post <codebase> <stage> <exit-code> <elapsed-s> [logfile]
stage_post() {
  local cb="$1" st="$2" rc="$3" el="$4" lf="${5:-}" icon=":white_check_mark:" tailtxt=""
  [ "$rc" -eq 0 ] || icon=":x:"
  if [ -n "$lf" ] && [ -f "$lf" ] && { [ "$rc" -ne 0 ] || [ "${VSQL_STAGE_TAILS:-0}" = 1 ]; }; then
    tailtxt=$'\n```\n'"$(tail -15 "$lf" | scrub)"$'\n```'
  fi
  dslack "$icon $cb stage=$st rc=$rc elapsed=${el}s$tailtxt"
}
env_post() {
  local info
  info=$({
    echo "uname: $(uname -srm)"; echo "user: $(id -un) uid=$(id -u)"
    echo "glibc: $(ldd --version 2>&1 | head -1)"
    echo "--- free -m"; free -m 2>&1
    echo "--- df -h /tmp /workspace"; df -h /tmp /workspace 2>&1
    echo "--- cgroup mem: $(cat /sys/fs/cgroup/memory.max 2>/dev/null) cpus: $(nproc 2>/dev/null)"
    echo "mysqld on PATH: $(command -v mysqld || echo none)"
    echo "libaio: $(ldconfig -p 2>/dev/null | grep -c 'libaio') libnuma: $(ldconfig -p 2>/dev/null | grep -c 'libnuma')"
  } 2>&1 | scrub)
  dslack ":mag: vsql environment"$'\n```\n'"$info"$'\n```'
}

env_post

RESULTS='[]'
OVERALL=0
INDEX=0

for CODEBASE in "${CODEBASES[@]}"; do
  PORT=$((BASE_PORT + INDEX))
  INDEX=$((INDEX + 1))
  VHOME="$WORKDIR/$CODEBASE"
  VBASE="$VHOME/.villagesql"
  VLOG="$LOG_DIR/$CODEBASE"
  STATUS="FAIL"; STAGE="install"; VERSION=""; RELEASE=""; ERRORS=0; PASSWORD=""
  STARTED=$(date -u +%s)

  log "=== $CODEBASE (port $PORT) ==="
  rm -rf "$VHOME"
  mkdir -p "$VBASE" "$VLOG"
  [ "${VSQL_TELEMETRY:-0}" = "1" ] || : > "$VBASE/.install_id"

  _S=$(date +%s)
  if HOME="$VHOME" PORT="$PORT" VSQL_CODEBASE="$CODEBASE" \
       INSTALL_METHOD=prebuilt VSQL_VERSION=stable \
       bash "$INSTALLER" </dev/null > "$VLOG/install.log" 2>&1; then
    PASSWORD=$(awk -F': *' '/^Root Password:/ {print $2; exit}' "$VBASE/credentials.txt")
    stage_post "$CODEBASE" install 0 $(( $(date +%s) - _S )) "$VLOG/install.log"
    RELEASE=$(awk -F': *' '/^Version:/ {print $2; exit}' "$VBASE/credentials.txt")
    BIN="$VBASE/prebuilt/bin"
    SOCKET="$VBASE/mysql.sock"
    MYSQL=("$BIN/mysql" --no-defaults --socket="$SOCKET" -uroot)
    export MYSQL_PWD="$PASSWORD"

    STAGE="connect"; _S=$(date +%s)
    if VERSION=$("${MYSQL[@]}" -NBe 'SELECT VERSION()' 2>>"$VLOG/sql-output.log"); then
      log "Server up: $VERSION ($RELEASE)"
      stage_post "$CODEBASE" start/connect 0 $(( $(date +%s) - _S ))
      STAGE="sql"; _S=$(date +%s)
      "${MYSQL[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$DATABASE\`"
      FORCE_OPT=()
      [ "${VSQL_FORCE:-0}" = "1" ] && FORCE_OPT=(--force)
      "${MYSQL[@]}" "${FORCE_OPT[@]}" --table --show-warnings --comments \
        --database="$DATABASE" < "$SQL_FILE" >> "$VLOG/sql-output.log" 2>&1
      SQL_RC=$?
      ERRORS=$(grep -c '^ERROR ' "$VLOG/sql-output.log" || true)
      stage_post "$CODEBASE" sql "$([ "$SQL_RC" -eq 0 ] && [ "$ERRORS" -eq 0 ] && echo 0 || echo "${SQL_RC:-1}")" $(( $(date +%s) - _S )) "$VLOG/sql-output.log"
      if [ "$SQL_RC" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
        STATUS="PASS"; STAGE="done"
      fi
    else
      stage_post "$CODEBASE" start/connect 1 $(( $(date +%s) - _S )) "$VLOG/sql-output.log"
      [ -f "$VBASE/mysql.log" ] && stage_post "$CODEBASE" mysqld-log 1 0 "$VBASE/mysql.log"
    fi
    _S=$(date +%s)

    "$BIN/mysqladmin" --no-defaults --socket="$SOCKET" -uroot shutdown >"$VLOG/shutdown.log" 2>&1; _RC=$?
    stage_post "$CODEBASE" shutdown "$_RC" $(( $(date +%s) - _S )) "$VLOG/shutdown.log"
    unset MYSQL_PWD
  else
    _RC=$?
    stage_post "$CODEBASE" install 1 $(( $(date +%s) - _S )) "$VLOG/install.log"
    [ -f "$VBASE/mysql.log" ] && stage_post "$CODEBASE" mysqld-log 1 0 "$VBASE/mysql.log"
    log "Installer failed; last lines:"
    tail -15 "$VLOG/install.log" | sed 's/^/    /'
  fi

  [ -f "$VBASE/mysql.log" ] && cp "$VBASE/mysql.log" "$VLOG/mysqld.log"
  for f in "$VLOG"/*.log; do redact "$f" "$PASSWORD"; done

  ELAPSED=$(( $(date -u +%s) - STARTED ))
  log "$CODEBASE: $STATUS (stage: $STAGE, SQL errors: $ERRORS, ${ELAPSED}s)"
  [ "$STATUS" = "PASS" ] || OVERALL=1
  slack "$([ "$STATUS" = PASS ] && echo ':white_check_mark:' || echo ':x:') $CODEBASE $STATUS (stage: $STAGE, ${ELAPSED}s)"

  RESULTS=$(jq -c \
    --arg codebase "$CODEBASE" --arg status "$STATUS" --arg stage "$STAGE" \
    --arg version "$VERSION" --arg release "$RELEASE" \
    --argjson errors "$ERRORS" --argjson seconds "$ELAPSED" \
    '. + [{codebase: $codebase, status: $status, stage: $stage, version: $version,
           release: $release, sql_errors: $errors, seconds: $seconds}]' <<<"$RESULTS")

  rm -rf "$VHOME"
done

jq -n \
  --arg timestamp "$STAMP" --arg host "$(uname -srm)" \
  --arg installer_sha256 "$INSTALLER_SHA" --arg sql_sha256 "$SQL_SHA" \
  --arg sql_file "$(basename "$SQL_FILE")" \
  --arg result "$([ $OVERALL -eq 0 ] && echo PASS || echo FAIL)" \
  --argjson variants "$RESULTS" \
  '$ARGS.named' > "$LOG_DIR/summary.json"

{
  echo "| Codebase | Result | Release | Server version | SQL errors | Seconds |"
  echo "|---|---|---|---|---|---|"
  jq -r '.variants[] | "| \(.codebase) | \(.status) | \(.release) | \(.version) | \(.sql_errors) | \(.seconds) |"' \
    "$LOG_DIR/summary.json"
} > "$LOG_DIR/summary.md"

echo
cat "$LOG_DIR/summary.md"
echo
log "Logs: $LOG_DIR"
exit $OVERALL
