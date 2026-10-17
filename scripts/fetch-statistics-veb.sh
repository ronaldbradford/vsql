#!/usr/bin/env bash
#
# fetch-statistics-veb.sh [outdir]
#
# Downloads the newest vsql_statistics release .veb for this machine
# (https://github.com/ronaldbradford/vsql-statistics/releases) and prints:
#   - the release tag, asset name and sha256
#   - the extension version and description from the .veb manifest.json
#   - the path of the .veb (last line of stdout; use it for VSQL_EXTRA_VEB)
#
# The SDK/protocol the .veb was built against is only visible once it is
# installed: run it through the runner, which prints it from
# INFORMATION_SCHEMA.EXTENSION_REGISTRATION (see sql/statistics.sql):
#
#   VEB=$(./scripts/fetch-statistics-veb.sh | tail -1)
#   VSQL_EXTRA_VEB="$VEB" ./scripts/vsql-test.sh sql/statistics.sql
#
# Environment: GITHUB_TOKEN (optional, avoids API rate limits).
set -euo pipefail

REPO="${VSQL_STATISTICS_REPO:-ronaldbradford/vsql-statistics}"
OUT="${1:-${TMPDIR:-/tmp}/vsql-statistics-veb}"
case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "unsupported OS" >&2; exit 2 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=$([ "$os" = darwin ] && echo arm64 || echo aarch64) ;; *) echo "unsupported arch" >&2; exit 2 ;; esac
AUTH=(); [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")

mkdir -p "$OUT"
# Newest release that actually has a .veb asset for this platform.
REL=$(curl -fsS "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases?per_page=20" |
  jq -c --arg suffix "-$os-$arch.veb" '[.[] | select(any(.assets[]; .name|endswith($suffix)))][0]')
[ -n "$REL" ] && [ "$REL" != null ] || { echo "No release of $REPO has a $os-$arch .veb asset" >&2; exit 1; }
TAG=$(jq -r .tag_name <<<"$REL")
URL=$(jq -r --arg suffix "-$os-$arch.veb" '.assets[]|select(.name|endswith($suffix))|.browser_download_url' <<<"$REL")
PUBLISHED=$(jq -r .published_at <<<"$REL")
curl -fsSL -o "$OUT/vsql_statistics.veb" "$URL"
chmod 644 "$OUT/vsql_statistics.veb"
tar -xf "$OUT/vsql_statistics.veb" -O manifest.json > "$OUT/manifest.json"
echo "release:   $TAG (published $PUBLISHED)"
echo "asset:     $URL"
echo "sha256:    $(sha256sum "$OUT/vsql_statistics.veb" | cut -d' ' -f1)"
echo "manifest:  name=$(jq -r .name "$OUT/manifest.json") version=$(jq -r .version "$OUT/manifest.json")"
echo "$OUT/vsql_statistics.veb"
