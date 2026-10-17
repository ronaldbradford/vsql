#!/usr/bin/env bash
#
# do-run.sh
#
# Run scripts/run-and-pr.sh on a throwaway DigitalOcean droplet: create it,
# install dependencies with cloud-init, clone this repo as the non-root
# "runner" user, run the tests, copy the logs back, and destroy the droplet.
#
# Usage (from anywhere in the repo):
#   ./digitalocean/do-run.sh run [options] [sql-file] [codebase ...]
#       --keep          leave the droplet running afterwards
#       --if-changed    skip (no droplet) if this release already passed here
#       --local         overlay local scripts/ and sql/ onto the clone, so
#                       uncommitted changes are tested
#   ./digitalocean/do-run.sh up | ssh | down | list
#   ./digitalocean/do-run.sh slack-test        post sample messages only (no droplet)
#   ./digitalocean/do-run.sh reap [MINUTES]   destroy vsql-test droplets older than MINUTES (default 90)
#
# Environment:
#   GH_TOKEN        Passed to run-and-pr.sh to push logs and open a PR.
#                   Unset = DRY_RUN=1 (logs are only copied back locally).
#   SLACK_BOT_TOKEN Optional; enables Slack posts here and on the droplet
#   SLACK_CHANNEL   Slack channel (default: C0CA2TF6W4C, as the Cloudflare runner)
#   RUN_SOURCE      Environment label in Slack, PR and build log (default: digitalocean)
#   BUILD_LOG_URL   Optional Build Log endpoint override
#   BASE_BRANCH     Branch to clone and target (default: main)
#   AUTO_MERGE=1    Passed through to run-and-pr.sh
#   DO_REGION       (default: syd1)    DO_SIZE  (default: s-2vcpu-4gb)
#   DO_IMAGE        (default: ubuntu-26-04-x64; must have glibc >= 2.42)
#   SSH_KEY         Private key whose .pub is in your DO account (default: ~/.ssh/id_ed25519)
#   DO_SSH_KEY_ID   DO key ID or fingerprint; skips the lookup from SSH_KEY.pub
#
# Requires doctl (authenticated: doctl auth init), jq and ssh.
#
# Exit status: run-and-pr.sh's exit status (0 = all variants passed).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
STATE=$HERE/.state
RESULTS=$HERE/results
TAG=vsql-test
REPO_URL=https://github.com/ronaldbradford/vsql.git

DO_REGION=${DO_REGION:-syd1}
DO_SIZE=${DO_SIZE:-s-2vcpu-4gb}
DO_IMAGE=${DO_IMAGE:-ubuntu-26-04-x64}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
BASE_BRANCH=${BASE_BRANCH:-main}
export SLACK_CHANNEL=${SLACK_CHANNEL:-C0CA2TF6W4C}
export RUN_SOURCE=${RUN_SOURCE:-digitalocean}

# Droplet IPs get recycled, so never record host keys.
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=30)

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; slack ":x: vsql droplet run aborted: $*"; exit 2; }

# Non-fatal Slack posts prefixed [RUN_SOURCE · RUN_HOST], same as run-and-pr.sh.
# Droplet messages set RUN_HOST to the droplet name, which is also the hostname
# run-and-pr.sh reports from on the droplet.
# shellcheck source=scripts/slack-lib.sh
. "$REPO_ROOT/scripts/slack-lib.sh"

need_tools() {
  local cmd
  for cmd in doctl jq ssh; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required (brew install doctl jq; doctl auth init)"
  done
}

droplet_id()   { cat "$STATE/droplet_id" 2>/dev/null || true; }
droplet_ip()   { cat "$STATE/droplet_ip" 2>/dev/null || true; }
droplet_name() { cat "$STATE/droplet_name" 2>/dev/null || true; }
rsh() { ssh "${SSH_OPTS[@]}" "root@$(droplet_ip)" "$@"; }

ssh_key_id() {
  [ -n "${DO_SSH_KEY_ID:-}" ] && { echo "$DO_SSH_KEY_ID"; return; }
  [ -f "$SSH_KEY.pub" ] || die "$SSH_KEY.pub not found; set SSH_KEY"
  local fp id
  fp=$(ssh-keygen -E md5 -lf "$SSH_KEY.pub" | awk '{print $2}' | sed 's/^MD5://')
  id=$(doctl compute ssh-key list -o json | jq -r --arg fp "$fp" '.[] | select(.fingerprint==$fp) | .id' | head -1)
  [ -n "$id" ] || die "$SSH_KEY.pub is not in your DigitalOcean account; add it with: doctl compute ssh-key import $(whoami)-vsql --public-key-file $SSH_KEY.pub"
  echo "$id"
}

latest_release() {
  curl -fsSL https://api.github.com/repos/villagesql/villagesql-server/releases/latest | jq -r '.tag_name // empty'
}

cmd_up() {
  [ -z "$(droplet_id)" ] || die "droplet $(droplet_id) already tracked in $STATE; run 'down' first"
  mkdir -p "$STATE"
  local name key out i
  name="vsql-test-$(date -u +%Y%m%dt%H%M%Sz)"
  key=$(ssh_key_id)
  doctl compute image get "$DO_IMAGE" >/dev/null 2>&1 \
    || die "image $DO_IMAGE not found; see: doctl compute image list-distribution"

  log "Creating $name ($DO_SIZE, $DO_IMAGE, $DO_REGION)"
  date +%s > "$STATE/started_at"
  echo "$name" > "$STATE/droplet_name"   # lets 'down' find it even if create times out
  out=$(doctl compute droplet create "$name" \
          --image "$DO_IMAGE" --size "$DO_SIZE" --region "$DO_REGION" \
          --ssh-keys "$key" --tag-names "$TAG" \
          --user-data-file "$HERE/cloud-init.yaml" \
          --wait -o json) || die "droplet create failed"
  jq -r '.[0].id' <<<"$out" > "$STATE/droplet_id"
  jq -r '.[0].networks.v4[] | select(.type=="public") | .ip_address' <<<"$out" > "$STATE/droplet_ip"
  log "Droplet $(droplet_id) at $(droplet_ip)"
  RUN_HOST=$name slack ":droplet: vsql droplet created ($DO_SIZE, $DO_REGION, $DO_IMAGE)"

  log "Waiting for ssh"
  for i in $(seq 60); do rsh true 2>/dev/null && break; sleep 5; done
  [ "$i" -lt 60 ] || die "ssh to $name never came up"

  log "Waiting for cloud-init"
  # cloud-init status: 0 done, 1 error, 2 done with recoverable errors.
  rsh cloud-init status --wait >/dev/null || log "cloud-init reported errors; see cloud-init-output.log in the results"
  log "Droplet ready after $(( $(date +%s) - $(cat "$STATE/started_at") ))s"
}

# Build the script that runs on the droplet as root. Secrets are written into
# this stdin stream, never into user-data or the ssh command line.
remote_script() {
  local overlay=$1; shift
  local v
  echo 'set -euo pipefail'
  for v in GH_TOKEN SLACK_BOT_TOKEN SLACK_CHANNEL BUILD_LOG_URL AUTO_MERGE DRY_RUN BASE_BRANCH RUN_SOURCE; do
    if [ -n "${!v:-}" ]; then printf 'export %s=%q\n' "$v" "${!v}"; fi
  done
  if [ $# -gt 0 ]; then printf 'ARGS=(%s)\n' "$(printf '%q ' "$@")"; else echo 'ARGS=()'; fi
  printf 'OVERLAY=%q\n' "$overlay"
  printf 'REPO_URL=%q\n' "$REPO_URL"
  cat <<'EOS'
REPO=/home/runner/vsql
rm -rf "$REPO"
runuser -u runner -- git clone -q --branch "$BASE_BRANCH" "$REPO_URL" "$REPO"
if [ -n "$OVERLAY" ]; then
  printf '%s' "$OVERLAY" | base64 -d | runuser -u runner -- tar xzf - -C "$REPO"
fi
cd "$REPO"
# runuser -u keeps the exported variables and switches HOME to /home/runner.
runuser -u runner -- ./scripts/run-and-pr.sh "${ARGS[@]}"
EOS
}

cmd_test() {
  local overlay=$1; shift
  [ -n "$(droplet_ip)" ] || die "no droplet tracked; run 'up' first"
  local dir rc=0
  dir=$RESULTS/$(droplet_name)
  mkdir -p "$dir"

  log "Running run-and-pr.sh on $(droplet_name) (DRY_RUN=${DRY_RUN:-0})"
  # build-log records the whole droplet run; run-and-pr.sh also records each
  # codebase from the droplet itself.
  remote_script "$overlay" "$@" \
    | "$REPO_ROOT/scripts/build-log" -d "vsql $DO_SIZE $DO_REGION (${RUN_SOURCE})" -- \
        ssh "${SSH_OPTS[@]}" "root@$(droplet_ip)" bash -s \
    | tee "$dir/console.log" || rc=$?

  log "Copying logs to ${dir#"$REPO_ROOT"/}"
  rsh 'tar czf - -C /home/runner/vsql logs -C /var/log cloud-init-output.log 2>/dev/null' \
    | tar xzf - -C "$dir" 2>/dev/null || log "could not copy all logs"
  return $rc
}

cmd_down() {
  local id secs price cost
  id=$(droplet_id)
  if [ -z "$id" ] && [ -n "$(droplet_name)" ]; then
    id=$(doctl compute droplet list --tag-name "$TAG" -o json \
         | jq -r --arg n "$(droplet_name)" '.[] | select(.name==$n) | .id')
  fi
  [ -n "$id" ] || { log "No droplet tracked"; rm -rf "$STATE"; return 0; }
  log "Destroying droplet $id"
  doctl compute droplet delete -f "$id"
  if [ -f "$STATE/started_at" ]; then
    secs=$(( $(date +%s) - $(cat "$STATE/started_at") ))
    price=$(doctl compute size list -o json | jq -r --arg s "$DO_SIZE" '.[] | select(.slug==$s) | .price_hourly')
    # Per-second billing, 60 s / $0.01 minimum.
    cost=$(awk -v s="$secs" -v p="${price:-0}" 'BEGIN{t=(s<60?60:s)*p/3600; printf "%.4f", (t<0.01?0.01:t)}')
    log "Droplet lived ${secs}s ≈ \$$cost ($DO_SIZE @ \$${price}/h)"
    RUN_HOST=$(droplet_name) slack ":wastebasket: vsql droplet destroyed after ${secs}s (≈ \$$cost)"
  fi
  rm -rf "$STATE"
}

cmd_run() {
  local keep=false if_changed=false local_overlay=false overlay="" tag rc=0
  while [ $# -gt 0 ]; do
    case $1 in
      --keep) keep=true ;;
      --if-changed) if_changed=true ;;
      --local) local_overlay=true ;;
      --) shift; break ;;
      -*) die "unknown option $1" ;;
      *) break ;;
    esac
    shift
  done

  tag=$(latest_release) || true
  [ -n "$tag" ] || die "could not read the latest VillageSQL release from GitHub"
  if $if_changed && [ "$tag" = "$(cat "$HERE/.last_passed_release" 2>/dev/null)" ]; then
    log "$tag already passed here; nothing to do (no droplet created)"
    return 0
  fi

  if [ -z "${GH_TOKEN:-}" ] && [ "${DRY_RUN:-0}" != 1 ]; then
    log "GH_TOKEN not set: running with DRY_RUN=1 (logs copied back here, no PR)"
    export DRY_RUN=1
  fi
  if $local_overlay; then
    overlay=$(tar czf - -C "$REPO_ROOT" scripts sql | base64 | tr -d '\n')
    log "Overlaying local scripts/ and sql/ onto the clone"
  fi

  # Destroy on any exit (success, failure, Ctrl-C) unless --keep.
  $keep || trap 'cmd_down' EXIT
  trap 'exit 130' INT TERM

  log "Testing VillageSQL $tag"
  cmd_up
  cmd_test "$overlay" "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "$tag" > "$HERE/.last_passed_release"
    log "All variants passed ($tag)"
  else
    log "Run failed ($tag); see ${RESULTS#"$REPO_ROOT"/}/$(droplet_name)"
  fi
  $keep && log "Droplet kept: $0 ssh   then   $0 down"
  return $rc
}

cmd_list() {
  doctl compute droplet list --tag-name "$TAG" --format ID,Name,PublicIPv4,Status,Created
}

# Backstop for droplets left by a killed laptop or CI runner.
cmd_reap() {
  local minutes=${1:-90} ids id
  ids=$(doctl compute droplet list --tag-name "$TAG" -o json \
        | jq -r --argjson m "$minutes" '.[] | select((.created_at | fromdateiso8601) < (now - $m*60)) | .id')
  [ -n "$ids" ] || { log "No $TAG droplets older than ${minutes}m"; return 0; }
  for id in $ids; do
    log "Reaping droplet $id"
    doctl compute droplet delete -f "$id"
    slack ":wastebasket: reaped leftover vsql droplet $id (older than ${minutes}m)"
  done
  if [ -n "$(droplet_id)" ] && grep -qx "$(droplet_id)" <<<"$ids"; then rm -rf "$STATE"; fi
}

# Sample messages only: what a droplet run posts, without creating anything.
cmd_slack_test() {
  local name T
  name="vsql-test-$(date -u +%Y%m%dt%H%M%Sz)"; T=":test_tube: test message, no droplet was created"
  RUN_HOST=$name "$REPO_ROOT/scripts/slack-test" || return 1
  SLACK_STRICT=1 RUN_HOST=$name slack ":droplet: vsql droplet created ($DO_SIZE, $DO_REGION, $DO_IMAGE) ($T)"
  SLACK_STRICT=1 RUN_HOST=$name slack ":wastebasket: vsql droplet destroyed after 0s (≈ \$0.0000) ($T)"
}

case ${1:-} in run|up|ssh|down|reap|list) need_tools ;; esac

case ${1:-} in
  run)  shift; cmd_run "$@" ;;
  up)   cmd_up ;;
  ssh)  ssh -t "${SSH_OPTS[@]}" "root@$(droplet_ip)" ;;
  down) cmd_down ;;
  reap) cmd_reap "${2:-90}" ;;
  list) cmd_list ;;
  slack-test) cmd_slack_test ;;
  *)    sed -n '3,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; exit 2 ;;
esac
