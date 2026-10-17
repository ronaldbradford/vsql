# shellcheck shell=bash
# slack-lib.sh: shared Slack helper, sourced by the test scripts.
#
# Every message is prefixed with where it came from, "[RUN_SOURCE · RUN_HOST]",
# so runs from different environments and machines can share one channel:
#   RUN_SOURCE  the environment, e.g. "cloudflare cron", "digitalocean",
#               "macbook" (default: manual)
#   RUN_HOST    the machine (default: short hostname)
#
# slack MESSAGE...  posts through scripts/slack-post. Non-fatal and a no-op
# without SLACK_BOT_TOKEN, unless SLACK_DRY_RUN=1 (prints instead of posting).

VSQL_SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

slack_prefix() {
  printf '[%s · %s]' "${RUN_SOURCE:-manual}" \
    "${RUN_HOST:-$(hostname -s 2>/dev/null || uname -n)}"
}

slack() {
  [ -n "${SLACK_BOT_TOKEN:-}" ] || [ "${SLACK_DRY_RUN:-0}" = 1 ] || return 0
  SLACK_PREFIX=$(slack_prefix) "$VSQL_SCRIPTS_DIR/slack-post" "$*" >/dev/null || true
  return 0
}
