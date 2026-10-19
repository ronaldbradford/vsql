#!/bin/bash -e
# VillageSQL Installation Script
# Prevents partial execution if download is interrupted

# The bash guard must be the first executable statement, ABOVE all function
# definitions. When piped (`curl ... | sh`) the shebang is ignored and dash
# runs the script; dash parses each command as it goes, and it rejects the
# bashisms inside readBundledExtensions (the `<<<` here-string) at function-
# definition time — before a guard inside main() would ever execute. Placed
# here, the guard runs before the parser reaches any bashism.
if ! command -v bash >/dev/null 2>&1; then
    echo "Error: bash is required to run this installer."
    echo "Install bash and try again."
    exit 1
fi

if [ -z "${BASH_VERSION}" ]; then
    echo "Error: This installer requires bash. Please re-run with:"
    echo ""
    echo "  curl -fsSL https://install.villagesql.com | bash"
    echo ""
    exit 1
fi

# Read user input from the terminal, aborting when none is available. Piped
# installs (`curl ... | bash`) prompt via /dev/tty; in headless environments
# (CI, docker build) that read fails. Without this abort, a failed read left
# the answer variable empty and fell through the install-method menu's
# catch-all else — silently starting a full source build.
prompt() {
    # 2>/dev/null must precede </dev/tty: redirections apply left to right, so
    # stderr is already silenced when the tty open fails — otherwise bash
    # prints a raw "/dev/tty: Device not configured" above our message.
    if ! read "$@" 2>/dev/null </dev/tty; then
        echo ""
        echo "Error: This installer is interactive and requires a terminal."
        echo "Re-run it from an interactive shell, or run non-interactively with:"
        echo ""
        echo "  VSQL_CODEBASE=mysql-8.4|percona-8.4|mysql-9.7  (required)"
        echo "  INSTALL_METHOD=docker|prebuilt|source          (required)"
        echo "  VSQL_VERSION=stable|nightly|latest             (source: stable|nightly|latest,"
        echo "                                                  docker and prebuilt: stable only)"
        echo ""
        exit 1
    fi
}

readBundledExtensions() {
    EXTENSIONS_LIST="$1"

    if [[ ! -f "$EXTENSIONS_LIST" ]]; then
        echo ""
        return
    fi

    # Read and parse the list of extensions
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Parse "url [branch-or-tag] [key=value ...]" — all fields after url are optional
        read -ra FIELDS <<< "$line"
        SOURCE="${FIELDS[0]%/}"
        BRANCH="${FIELDS[1]:-}"
        REPO_NAME="${SOURCE##*/}"

        # Confirm the extension is bundled
        BUNDLE=true
        for FIELD in "${FIELDS[@]:2}"; do
            [[ "${FIELD}" == "bundle=false" || "${FIELD}" == "bundle=no" ]] && BUNDLE=false
        done
        if [[ "${BUNDLE}" == "false" ]]; then
            continue
        fi

        RESULT="${RESULT} ${REPO_NAME}"
    done < "$EXTENSIONS_LIST"
    echo ${RESULT}
}

main() {
    # bash guard lives at the top of the file (above function definitions) —
    # see the comment there for why it cannot live here.
    set -o pipefail

    MYSQL_DEFAULT_PORT=3306
    PORT=${PORT:-$MYSQL_DEFAULT_PORT}

    OS=$(uname -s)
    ARCH=$(uname -m)

    # Anonymous install ID — stable per machine, stored in ~/.villagesql/.install_id
    # To opt out of tracking, write an empty file: touch ~/.villagesql/.install_id
    _VSQL_ID_FILE="${HOME}/.villagesql/.install_id"
    if [ -f "$_VSQL_ID_FILE" ] && [ ! -s "$_VSQL_ID_FILE" ]; then
        _VSQL_ANON_ID=""  # empty file = opted out
    elif [ -f "$_VSQL_ID_FILE" ]; then
        _VSQL_ANON_ID=$(cat "$_VSQL_ID_FILE" 2>/dev/null || echo "anon")
    else
        if [ -f /proc/sys/kernel/random/uuid ]; then
            _VSQL_ANON_ID=$(tr -d '-' < /proc/sys/kernel/random/uuid)
        elif command -v uuidgen >/dev/null 2>&1; then
            _VSQL_ANON_ID=$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')
        else
            _VSQL_ANON_ID="$(date +%s)${RANDOM}${RANDOM}"
        fi
        # Creating the id file as root would leave a root-owned file behind,
        # which is what the root check below exists to prevent. A refused run
        # never needs the id again, so it stays in memory.
        if [ "$(id -u)" -ne 0 ]; then
            mkdir -p "${HOME}/.villagesql" 2>/dev/null || true
            printf '%s' "$_VSQL_ANON_ID" > "$_VSQL_ID_FILE" 2>/dev/null || true
        fi
    fi

    _send_event() {
        local _event="$1" _extra="${2:-}"
        [ -n "$_VSQL_ANON_ID" ] || return 0
        command -v curl >/dev/null 2>&1 || return 0
        local _ts _json _b64
        _ts=$(date +%s)
        _json=$(printf '[{"event":"%s","properties":{"token":"86f474ad75c034a2e021b35fd3d4b5f1","distinct_id":"%s","time":%d,"os":"%s","arch":"%s"%s}}]' \
            "$_event" "$_VSQL_ANON_ID" "$_ts" "$OS" "$ARCH" "$_extra")
        _b64=$(printf '%s' "$_json" | base64 | tr -d '\n')
        curl --silent --max-time 5 --output /dev/null \
            --request POST \
            --url "https://api.mixpanel.com/track" \
            --data "data=$_b64" 2>/dev/null
    }

    _track() { _send_event "$@" & }

    VSQL_STAGE="starting up"

    # Adding a second `trap ... EXIT` replaces this one and silently stops
    # failure reporting from that line on. Register temp paths here instead.
    VSQL_CLEANUP_DIR=""

    _on_exit() {
        local _rc=$?
        [ -n "$VSQL_CLEANUP_DIR" ] && rm -rf "$VSQL_CLEANUP_DIR"
        [ "$_rc" -eq 0 ] && return 0
        # Foreground, not _track: a backgrounded curl dies with the process
        # group on Ctrl-C or a closed terminal, which is when this must send.
        _send_event "Server Install Failed" ",\"stage\":\"${VSQL_STAGE}\",\"method\":\"${INSTALL_METHOD:-unknown}\",\"codebase\":\"${CODEBASE:-unknown}\",\"exit_code\":${_rc}"
    }

    trap _on_exit EXIT
    trap 'VSQL_STAGE="interrupted (Ctrl-C)"; exit 130' INT
    trap 'VSQL_STAGE="terminal closed"; exit 129' HUP
    trap 'VSQL_STAGE="terminated"; exit 143' TERM

    # Running as root is not supported: VillageSQL installs into the invoking
    # user's home directory and refuses to leave root-owned files behind.
    # Below the traps so the refusal is reported like any other failed exit.
    if [ "$(id -u)" -eq 0 ]; then
        VSQL_STAGE="running as root"
        echo "Error: Running this installer as root is not supported."
        echo "Re-run it as a regular user (e.g. without sudo)."
        exit 1
    fi

    IS_UPDATE=false
    SHORTCUTS_CREATED=false

    echo
    echo "              ====                                                                   "
    echo "               =========                                                             "
    echo "                =============                                                        "
    echo "                 =================                                                   "
    echo "                  =====================                                              "
    echo "                  =====================+*#                                           "
    echo "                   ============+++**###%#**                                          "
    echo "                     ##**+**########%%%%***                                          "
    echo "                    ##############%%%%%#****            =                            "
    echo "                     ###########%%%%%%%******         ========                       "
    echo "                      ########%%%%%%%%********      ==============                   "
    echo "                       ####%%%%%%%%%%#********    =====================              "
    echo "                       ##%%%%%%%%%%%%**********    ===####++================         "
    echo "                        %%%%%%%%%%%%#**********+      %%%#*######***++++=========    "
    echo "                            %%%%%%%%*****+++=======   %%%***##################***+** "
    echo "                                %%%**+++============== %***** #################      "
    echo "                                    ###################******                        "
    echo "                                      #########%%%%%%%%#==+***                       "
    echo "                                       **#%%%%%%%%%%%%%%*====+                       "
    echo "                                      ********##%%%%%%%%%+====                       "
    echo "                                     ***************##%%%%==                         "
    echo "                                   *********************###                          "
    echo "                                  *****************##%%%%                            "
    echo "                                 **************#%%%%%%%%                             "
    echo "                                **********##%%%%%%%%%%                               "
    echo "                              *******##%%%%%%%%%%%%%                                 "
    echo "                             ***##%%%%%%%%%%%%%%%%                                   "
    echo "                            *##%%%%%%                                                "
    echo
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                                                      ║"
    echo "║               VillageSQL Installation                ║"
    echo "║             MySQL for the Agentic AI Era             ║"
    echo "║                                                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo

    # Check OS compatibility
    if [ "${OS}" != "Linux" ] && [ "${OS}" != "Darwin" ]; then
        echo "Error: VillageSQL currently supports Linux and macOS only."
        echo "Your OS: ${OS}"
        exit 1
    fi

    # Check architecture
    if [ "${ARCH}" != "x86_64" ] && [ "${ARCH}" != "amd64" ] && [ "${ARCH}" != "arm64" ] && [ "${ARCH}" != "aarch64" ]; then
        echo "Warning: Architecture '${ARCH}' may not be fully supported."
        printf "Continue anyway? (y/n) "
        # Not prompt(): its abort message suggests setting INSTALL_METHOD, but
        # env vars cannot answer this safety question — an unsupported arch
        # must be confirmed by a human at a terminal.
        if ! read -n 1 -r REPLY 2>/dev/null </dev/tty; then
            echo ""
            echo "Error: Architecture '${ARCH}' may not be fully supported, and no"
            echo "terminal is available to confirm continuing. Run interactively to proceed."
            exit 1
        fi
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # ─── Architecture Naming ───
    # The published artifacts spell the architecture two different ways, and
    # neither always matches `uname -m`:
    #   Docker image tags:  amd64 | arm64
    #   Release tarballs:   linux-x86_64 | linux-aarch64 | macos-arm64
    # Normalize once here so the Docker and prebuilt paths interpolate a name
    # that actually exists instead of whatever uname happened to report
    # (uname says amd64 on some systems, x86_64 on others; aarch64 on Linux
    # arm but arm64 on Apple silicon). Source builds compile for the host and
    # need neither name.
    case "${ARCH}" in
        x86_64|amd64)  DOCKER_ARCH="amd64"; ASSET_ARCH="x86_64" ;;
        arm64|aarch64) DOCKER_ARCH="arm64"; ASSET_ARCH="arm64" ;;
        *)             DOCKER_ARCH="${ARCH}"; ASSET_ARCH="${ARCH}" ;;
    esac
    # Linux arm tarballs are published as aarch64, macOS ones as arm64.
    if [ "${OS}" = "Linux" ] && [ "${ASSET_ARCH}" = "arm64" ]; then
        ASSET_ARCH="aarch64"
    fi

    # Check if port is available
    check_port() {
        local _prev_stage="$VSQL_STAGE"
        VSQL_STAGE="checking port"
        echo "Checking if port ${PORT} is available..."
        PORT_IN_USE=false
        if command -v lsof >/dev/null 2>&1; then
            if lsof -Pi :${PORT} -sTCP:LISTEN -t >/dev/null 2>&1 || sudo -n lsof -Pi :${PORT} -sTCP:LISTEN -t >/dev/null 2>&1; then
                PORT_IN_USE=true
            fi
        elif command -v ss >/dev/null 2>&1; then
            if ss -tlnp "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
                PORT_IN_USE=true
            fi
        fi
        if [ "$PORT_IN_USE" = true ]; then
            echo
            PORT_MSG="⚠ Port ${PORT} Already In Use"
            PORT_MSG_LEN=${#PORT_MSG}
            PORT_PAD_LEFT=$(( (54 - PORT_MSG_LEN) / 2 ))
            PORT_PAD_RIGHT=$(( 54 - PORT_MSG_LEN - PORT_PAD_LEFT ))
            echo "╔══════════════════════════════════════════════════════╗"
            echo "║                                                      ║"
            printf "║%${PORT_PAD_LEFT}s%s%${PORT_PAD_RIGHT}s║\n" "" "$PORT_MSG" ""
            echo "║                                                      ║"
            echo "╚══════════════════════════════════════════════════════╝"
            echo
            echo "Port ${PORT} is already in use by another process."
            echo "Please stop your existing MySQL server first:"
            echo
            echo "  # Check what's using port ${PORT}:"
            echo "  sudo lsof -i :${PORT}"
            echo

            # If a prior VillageSQL install left credentials behind, surface its
            # exact stop command — chances are it's what the user is hitting.
            # Inline the saved password (mysqladmin accepts -pPASSWORD with no
            # space) so the suggestion is directly copy-pasteable.
            VSQL_CREDS="${HOME}/.villagesql/credentials.txt"
            if [ -f "${VSQL_CREDS}" ]; then
                VSQL_STOP_CMD=$(awk '/^Stop Server:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "${VSQL_CREDS}")
                VSQL_STOP_PW=$(awk -F': *' '/^Root Password:/{print $2; exit}' "${VSQL_CREDS}")
                if [ -n "${VSQL_STOP_CMD}" ]; then
                    if [ -n "${VSQL_STOP_PW}" ]; then
                        VSQL_STOP_CMD=${VSQL_STOP_CMD/ -p / -p${VSQL_STOP_PW} }
                    fi
                    echo "  # If it's VillageSQL from a previous install:"
                    echo "  ${VSQL_STOP_CMD}"
                    echo
                fi
            fi

            echo "  # If it's MySQL, stop it:"
            echo "  brew services stop mysql    # Homebrew"
            echo "  sudo systemctl stop mysql   # Linux systemd"
            echo
            echo "Then re-run this installer."
            echo
            exit 1
        fi
        echo "✓ Port ${PORT} is available"
        VSQL_STAGE="$_prev_stage"
        echo
    }

    start_mysqld() {
        # Capture stderr instead of discarding it: failures that happen before
        # mysqld opens --log-error (an unknown option, a missing shared
        # library, an unwritable datadir) only ever surface there, and those
        # are exactly the ones worth showing the user.
        : > "${INSTALL_BASE}/mysqld-start.err"
        "${BUILD_DIR}/bin/mysqld" \
          --datadir="${DATA_DIR}" \
          --socket="${INSTALL_BASE}/mysql.sock" \
          --port=${PORT} \
          --pid-file="${INSTALL_BASE}/mysql.pid" \
          --log-error="${INSTALL_BASE}/mysql.log" \
          --vsql_allow_preview_extensions=ON \
          --daemonize 2>"${INSTALL_BASE}/mysqld-start.err"
    }

    # Poll for readiness rather than sleeping a fixed interval: a cold InnoDB
    # start on a slow disk can take well over five seconds, while a server
    # that died should be reported at once instead of after the full wait.
    wait_for_server() {
        SERVER_WAIT_TIMEOUT="${1:-30}"
        SERVER_WAIT_ELAPSED=0
        while [ "${SERVER_WAIT_ELAPSED}" -lt "${SERVER_WAIT_TIMEOUT}" ]; do
            # "Access denied" means the server answered — it is up, we just
            # did not hand mysqladmin credentials. Treat it as alive.
            if PING_OUT=$("${BUILD_DIR}/bin/mysqladmin" --socket="${INSTALL_BASE}/mysql.sock" ping 2>&1); then
                return 0
            elif printf '%s' "${PING_OUT}" | grep -q "Access denied"; then
                return 0
            fi
            sleep 1
            printf "."
            SERVER_WAIT_ELAPSED=$((SERVER_WAIT_ELAPSED + 1))
        done
        return 1
    }

    # Everything mysqld managed to say before giving up. The error log is the
    # useful part; the stderr capture covers the case where it never got far
    # enough to open one.
    show_server_log() {
        LOG_LINES="${1:-10}"
        LOG_SHOWN=false
        if [ -s "${INSTALL_BASE}/mysqld-start.err" ]; then
            echo "Startup output from mysqld:"
            echo
            tail -${LOG_LINES} "${INSTALL_BASE}/mysqld-start.err" | sed 's/^/  /'
            echo
            LOG_SHOWN=true
        fi
        if [ -s "${INSTALL_BASE}/mysql.log" ]; then
            echo "Last ${LOG_LINES} lines of ${INSTALL_BASE}/mysql.log:"
            echo
            tail -${LOG_LINES} "${INSTALL_BASE}/mysql.log" | sed 's/^/  /'
            echo
            LOG_SHOWN=true
        fi
        if [ "${LOG_SHOWN}" = false ]; then
            echo "mysqld wrote no output at all — not even to ${INSTALL_BASE}/mysql.log."
            echo "That usually means it could not be executed, or ${INSTALL_BASE}"
            echo "is not writable."
            echo
        fi
    }

    # Loud, actionable failure. A silent "Warning: server may not have started"
    # left users with no idea what went wrong, so lead with the log.
    server_start_failed() {
        VSQL_STAGE="$1"
        echo
        FAIL_MSG="⚠ VillageSQL Server Failed to Start"
        FAIL_MSG_LEN=${#FAIL_MSG}
        FAIL_PAD_LEFT=$(( (54 - FAIL_MSG_LEN) / 2 ))
        FAIL_PAD_RIGHT=$(( 54 - FAIL_MSG_LEN - FAIL_PAD_LEFT ))
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║                                                      ║"
        printf "║%${FAIL_PAD_LEFT}s%s%${FAIL_PAD_RIGHT}s║\n" "" "$FAIL_MSG" ""
        echo "║                                                      ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo
        echo "The install completed, but the server did not come up (${VSQL_STAGE})."
        echo
        show_server_log 10
        echo "Most likely causes:"
        echo "  • Port ${PORT} was taken by another MySQL/MariaDB between the"
        echo "    check at the start of this install and now"
        echo "  • ${DATA_DIR} belongs to another user, or was initialized by a"
        echo "    different VillageSQL codebase — data created by mysql-8.4 will"
        echo "    not open under mysql-9.7 without an upgrade"
        echo "  • Not enough memory for the InnoDB buffer pool"
        echo
        echo "Full log: ${INSTALL_BASE}/mysql.log"
        echo
        echo "To see the error directly, start it in the foreground:"
        echo "  ${BUILD_DIR}/bin/mysqld --datadir=${DATA_DIR} --socket=${INSTALL_BASE}/mysql.sock --port=${PORT} --log-error=stderr --vsql_allow_preview_extensions=ON"
        echo
    }

    # ─── Server Codebase Selection ───
    VSQL_STAGE="selecting codebase"
    # VillageSQL is published on three upstream server bases. The choice picks
    # the Docker image tag, the release asset, and the git ref for source
    # builds, so it has to be settled before anything else can be resolved.
    # Non-interactive override: VSQL_CODEBASE=mysql-8.4|percona-8.4|mysql-9.7.
    if [ -n "${VSQL_CODEBASE:-}" ]; then
        case "$VSQL_CODEBASE" in
            mysql-8.4|percona-8.4|mysql-9.7) ;;
            *)
                echo "Error: Unknown VSQL_CODEBASE '${VSQL_CODEBASE}'."
                echo "Use mysql-8.4, percona-8.4, or mysql-9.7."
                exit 1
                ;;
        esac
        CODEBASE="$VSQL_CODEBASE"
        echo "Server codebase: ${CODEBASE} (set via VSQL_CODEBASE)"
        echo
    else
        echo "Which codebase of VillageSQL Server would you like to install?"
        echo
        echo "  1) MySQL 8.4    (recommended)"
        echo "  2) Percona 8.4"
        echo "  3) MySQL 9.7"
        echo
        printf "Select [1-3]: "
        prompt CODEBASE_CHOICE
        echo

        case "$CODEBASE_CHOICE" in
            2) CODEBASE="percona-8.4" ;;
            3) CODEBASE="mysql-9.7" ;;
            *) CODEBASE="mysql-8.4" ;;
        esac
        echo "Server codebase: ${CODEBASE}"
        echo
    fi

    # Set once a channel has been picked; referenced by the failure tracker,
    # which can fire before either path assigns it.
    VSQL_CHANNEL="stable"

    # Release assets are named
    #   villagesql-dev-server-<codebase>_<version>-<os>-<arch>.tar.gz
    # where <version> comes from the server's VSQL_VERSION file and does not
    # always equal the release tag — tag "0.0.3" shipped "0.0.3-dev" assets.
    # Match on the codebase and platform ends of the name and let the middle
    # vary, so this survives changes to how the version string is spelled.
    find_prebuilt_url() {
        printf '%s' "$1" \
            | grep '"browser_download_url"' \
            | grep -- "-${CODEBASE}_" \
            | grep -- "-${PREBUILT_PLATFORM}\.tar\.gz" \
            | head -1 \
            | sed 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/'
    }

    # ─── Fetch Release Info ───
    VSQL_STAGE="fetching release info"
    # All three methods need the current release: Docker tags and prebuilt
    # assets both embed the version, and source builds clone the release's
    # publish tag. So unlike previous versions this fetch is unconditional —
    # the version is never hardcoded, always read from the latest release.
    PREBUILT_OS=$(echo "$OS" | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/')
    PREBUILT_PLATFORM="${PREBUILT_OS}-${ASSET_ARCH}"

    echo "Fetching latest stable release..."
    # `|| true` on every lookup that is allowed to come back empty: run as an
    # executable the shebang's `-e` is active, and a failing curl or an
    # unmatched grep would otherwise kill the installer before it could print
    # the explanation below. (Piped through bash, `-e` is off — but that is not
    # something to rely on.)
    # -w on the status instead of -f on the body: a rate-limited lookup is an
    # HTTP 403, and -f discards it, which is why it read as a network problem.
    RELEASE_JSON=$(curl -sSL -w '\n%{http_code}' "https://api.github.com/repos/villagesql/villagesql-server/releases/latest" 2>/dev/null) || true
    RELEASE_HTTP=${RELEASE_JSON##*$'\n'}
    RELEASE_JSON=${RELEASE_JSON%$'\n'*}
    if [ "$RELEASE_HTTP" = "403" ] || [ "$RELEASE_HTTP" = "429" ]; then
        VSQL_STAGE="github rate limit"
        echo "Error: GitHub rate limit reached (60 requests/hour per IP)."
        echo "This resets hourly — try again shortly."
        exit 1
    fi
    if [ -z "$RELEASE_JSON" ]; then
        echo "Error: Could not fetch the latest release info."
        echo "Check your network connection and try again."
        exit 1
    fi
    LATEST_TAG=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/') || true
    if [ -z "$LATEST_TAG" ]; then
        echo "Error: Could not fetch the latest release tag."
        echo "Check your network connection and try again."
        exit 1
    fi
    # LATEST_TAG is the git ref as GitHub reports it; releases are tagged
    # `release/<version>` since 0.0.6 (0.0.5 and earlier were bare). Docker
    # tags, publish refs and asset names all embed the bare version, and a
    # `/` is not even legal in a Docker tag — so derive it once here. Stripping
    # a prefix that isn't there is a no-op, which keeps both schemes working.
    # Use LATEST_TAG only where an actual git ref is wanted.
    LATEST_VERSION="${LATEST_TAG#release/}"

    echo "Latest stable release: ${LATEST_VERSION}"
    echo

    # Whether a stable prebuilt exists for this codebase and platform. The
    # method menu keys off this; the nightly asset is looked up later, only
    # if the user actually asks for nightly.
    STABLE_PREBUILT_URL=$(find_prebuilt_url "$RELEASE_JSON") || true
    PREBUILT_URL="${STABLE_PREBUILT_URL}"

    # ─── Install Method Selection ───
    VSQL_STAGE="selecting install method"
    HAS_DOCKER=false
    command -v docker >/dev/null 2>&1 && HAS_DOCKER=true

    # Non-interactive override for CI, Dockerfiles, and AI agents:
    # INSTALL_METHOD=docker|prebuilt|source skips the menu entirely.
    if [ -n "${INSTALL_METHOD:-}" ]; then
        case "$INSTALL_METHOD" in
            docker)
                if [ "$HAS_DOCKER" != true ]; then
                    echo "Error: INSTALL_METHOD=docker, but docker is not installed."
                    exit 1
                fi
                ;;
            prebuilt)
                if [ -z "$PREBUILT_URL" ] && [ "${VSQL_VERSION:-stable}" = "stable" ]; then
                    echo "Error: INSTALL_METHOD=prebuilt, but no stable prebuilt binary is"
                    echo "published for ${CODEBASE} on ${PREBUILT_PLATFORM}."
                    exit 1
                fi
                ;;
            source) ;;
            *)
                echo "Error: Unknown INSTALL_METHOD '${INSTALL_METHOD}'. Use docker, prebuilt, or source."
                exit 1
                ;;
        esac
        # Which channels a method can offer differs: Docker publishes stable
        # images only, prebuilt binaries exist for stable only, and a source
        # build can check out any ref including main.
        if [ "$INSTALL_METHOD" = "docker" ] && [ -n "${VSQL_VERSION:-}" ] && [ "${VSQL_VERSION}" != "stable" ]; then
            echo "Error: VSQL_VERSION=${VSQL_VERSION} is not available for INSTALL_METHOD=docker."
            echo "Only stable images are published to Docker Hub."
            exit 1
        fi
        # Nightly is rejected here alongside latest: the nightly.latest git tag
        # has no GitHub release behind it, so there are no assets to download
        # and every nightly prebuilt attempt dead-ends.
        if [ "$INSTALL_METHOD" = "prebuilt" ] && [ -n "${VSQL_VERSION:-}" ] && [ "${VSQL_VERSION}" != "stable" ]; then
            echo "Error: VSQL_VERSION=${VSQL_VERSION} is not available for INSTALL_METHOD=prebuilt."
            echo "Binaries are only attached to stable releases. Build it from"
            echo "source instead:"
            echo
            echo "  curl -fsSL https://install.villagesql.com | \\"
            echo "    VSQL_CODEBASE=${CODEBASE} INSTALL_METHOD=source VSQL_VERSION=${VSQL_VERSION} bash"
            exit 1
        fi
        echo "Install method: ${INSTALL_METHOD} (set via INSTALL_METHOD)"
    elif [ "$HAS_DOCKER" = true ] || [ -n "$PREBUILT_URL" ]; then
        echo "How would you like to install VillageSQL?"
        echo

        OPTION=1
        OPT_DOCKER=0; OPT_PREBUILT=0

        if [ "$HAS_DOCKER" = true ]; then
            OPT_DOCKER=$OPTION
            echo "  ${OPTION}) Docker (Fastest, easiest to manage)"
            OPTION=$((OPTION + 1))
        fi

        if [ -n "$PREBUILT_URL" ]; then
            OPT_PREBUILT=$OPTION
            echo "  ${OPTION}) Prebuilt Binary (Fast, no compilation needed)"
            OPTION=$((OPTION + 1))
        fi

        echo "  ${OPTION}) Build from Source (Slower, compiles everything locally)"
        echo

        printf "Select [1-%d]: " "${OPTION}"
        prompt INSTALL_CHOICE
        echo

        if [ "$INSTALL_CHOICE" = "$OPT_DOCKER" ]; then
            INSTALL_METHOD="docker"
        elif [ "$INSTALL_CHOICE" = "$OPT_PREBUILT" ]; then
            INSTALL_METHOD="prebuilt"
        else
            INSTALL_METHOD="source"
        fi
    else
        INSTALL_METHOD="source"
    fi

    # ─── Release Channel Selection ───
    VSQL_STAGE="selecting release channel"
    # What each method can actually offer:
    #   docker    stable only — Docker Hub carries released images
    #   prebuilt  stable only — nothing is attached to the nightly tag. It
    #             exists as a git ref, but there is no GitHub *release* behind
    #             it, so the API 404s and there are no assets to download.
    #   source    stable | nightly | latest — a build can check out any ref
    # Only source is therefore asked; the other two have nothing to choose.
    # Non-interactive override: VSQL_VERSION=stable|nightly|latest.
    if [ "$INSTALL_METHOD" = "docker" ]; then
        VSQL_CHANNEL="stable"
    elif [ -n "${VSQL_VERSION:-}" ]; then
        case "$VSQL_VERSION" in
            stable|nightly|latest) VSQL_CHANNEL="$VSQL_VERSION" ;;
            *)
                echo "Error: Unknown VSQL_VERSION '${VSQL_VERSION}'. Use stable, nightly, or latest."
                exit 1
                ;;
        esac
        echo "Version: ${VSQL_CHANNEL} (set via VSQL_VERSION)"
        echo
    elif [ "$INSTALL_METHOD" != "source" ]; then
        VSQL_CHANNEL="stable"
    else
        echo "Which version would you like?"
        echo
        echo "  1) Stable   (latest release: ${LATEST_VERSION})"
        echo "  2) Nightly  (most recent nightly build)"
        echo "  3) Latest   (last commit on main — bleeding edge)"
        echo
        printf "Select [1-3]: "
        prompt CHANNEL_CHOICE
        echo

        case "$CHANNEL_CHOICE" in
            2) VSQL_CHANNEL="nightly" ;;
            3) VSQL_CHANNEL="latest" ;;
            *) VSQL_CHANNEL="stable" ;;
        esac
        echo "Version: ${VSQL_CHANNEL}"
        echo
    fi

    # Prebuilt installs are always the stable release: the menu no longer
    # offers anything else, and the non-interactive guard above rejects it.
    PREBUILT_LABEL="${LATEST_VERSION}"

    # ─── Docker Install Path ───
    if [ "$INSTALL_METHOD" = "docker" ]; then
        VSQL_STAGE="docker install"
        echo "Installing via Docker..."
        echo

        # `docker` being on PATH doesn't mean the daemon is running.
        # `docker info` is the canonical liveness check — fail fast with a
        # clear message so the user isn't left staring at a cryptic
        # "Cannot connect to the Docker daemon" error from `docker pull`.
        if ! docker info >/dev/null 2>&1; then
            echo
            DOCKER_MSG="⚠ Docker Is Not Running"
            DOCKER_MSG_LEN=${#DOCKER_MSG}
            DOCKER_PAD_LEFT=$(( (54 - DOCKER_MSG_LEN) / 2 ))
            DOCKER_PAD_RIGHT=$(( 54 - DOCKER_MSG_LEN - DOCKER_PAD_LEFT ))
            echo "╔══════════════════════════════════════════════════════╗"
            echo "║                                                      ║"
            printf "║%${DOCKER_PAD_LEFT}s%s%${DOCKER_PAD_RIGHT}s║\n" "" "$DOCKER_MSG" ""
            echo "║                                                      ║"
            echo "╚══════════════════════════════════════════════════════╝"
            echo
            echo "Docker is installed but the Docker daemon isn't running."
            echo "Please start Docker, then re-run this installer:"
            echo
            if [ "${OS}" = "Darwin" ]; then
                echo "  # Start Docker Desktop:"
                echo "  open -a Docker"
            else
                echo "  # Start the Docker service:"
                echo "  sudo systemctl start docker"
            fi
            echo
            exit 1
        fi

        _track "Server Install Started" ",\"method\":\"docker\",\"codebase\":\"${CODEBASE}\",\"arch\":\"${DOCKER_ARCH}\""

        check_port

        # Stop and remove existing vsql container if present
        if docker ps -a --format '{{.Names}}' | grep -q '^vsql$'; then
            echo "Removing existing 'vsql' container..."
            docker rm -f vsql >/dev/null 2>&1
        fi

        # Generate random password
        MYSQL_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

        # Images are tagged <codebase>_<version>-<arch>, e.g.
        # villagesql/server:mysql-9.7_0.0.6-arm64. Pulling the arch-specific
        # tag rather than a manifest list keeps the pull honest on hosts where
        # Docker would otherwise silently emulate the wrong architecture.
        DOCKER_IMAGE="villagesql/server:${CODEBASE}_${LATEST_VERSION}-${DOCKER_ARCH}"

        echo "Pulling ${DOCKER_IMAGE}..."
        if ! docker pull "${DOCKER_IMAGE}"; then
            echo
            echo "Error: Could not pull ${DOCKER_IMAGE}."
            echo
            echo "That image tag may not be published for this codebase and"
            echo "architecture. Published tags are listed at:"
            echo "  https://hub.docker.com/r/villagesql/server/tags"
            echo
            echo "You can also install this codebase from source:"
            echo
            echo "  curl -fsSL https://install.villagesql.com | \\"
            echo "    VSQL_CODEBASE=${CODEBASE} INSTALL_METHOD=source VSQL_VERSION=stable bash"
            echo
            exit 1
        fi

        echo "Starting VillageSQL container..."
        if ! docker run -d --name vsql -e MYSQL_ROOT_PASSWORD="${MYSQL_PASSWORD}" -p ${PORT}:3306 "${DOCKER_IMAGE}"; then
            echo
            echo "Error: Could not start the 'vsql' container."
            exit 1
        fi

        # `docker run -d` returns 0 as soon as the container is created, even
        # if mysqld dies a second later. Confirm the server actually answers
        # before claiming success, and show the container log if it never does.
        printf "Waiting for the server to accept connections"
        DOCKER_READY=false
        DOCKER_WAIT=0
        while [ "${DOCKER_WAIT}" -lt 90 ]; do
            if docker exec vsql mysqladmin -u root -p"${MYSQL_PASSWORD}" ping >/dev/null 2>&1; then
                DOCKER_READY=true
                break
            fi
            if [ "$(docker inspect -f '{{.State.Running}}' vsql 2>/dev/null)" != "true" ]; then
                break
            fi
            sleep 1
            printf "."
            DOCKER_WAIT=$((DOCKER_WAIT + 1))
        done
        echo

        if [ "${DOCKER_READY}" != true ]; then
            echo
            DFAIL_MSG="⚠ VillageSQL Server Failed to Start"
            DFAIL_MSG_LEN=${#DFAIL_MSG}
            DFAIL_PAD_LEFT=$(( (54 - DFAIL_MSG_LEN) / 2 ))
            DFAIL_PAD_RIGHT=$(( 54 - DFAIL_MSG_LEN - DFAIL_PAD_LEFT ))
            echo "╔══════════════════════════════════════════════════════╗"
            echo "║                                                      ║"
            printf "║%${DFAIL_PAD_LEFT}s%s%${DFAIL_PAD_RIGHT}s║\n" "" "$DFAIL_MSG" ""
            echo "║                                                      ║"
            echo "╚══════════════════════════════════════════════════════╝"
            echo
            echo "The 'vsql' container was created from ${DOCKER_IMAGE},"
            echo "but the server never accepted a connection."
            echo
            echo "Last 10 lines of 'docker logs vsql':"
            echo
            docker logs --tail 10 vsql 2>&1 | sed 's/^/  /'
            echo
            echo "Most likely causes:"
            echo "  • The image was built for a different architecture than ${DOCKER_ARCH}"
            echo "  • Port ${PORT} was taken between the check above and now"
            echo "  • Docker has too little memory for the InnoDB buffer pool"
            echo
            echo "Full log:  docker logs vsql"
            echo "Try again: docker rm -f vsql && re-run this installer"
            echo
            VSQL_STAGE="docker run"
            exit 1
        fi

        echo
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║                                                      ║"
        echo "║            ✓ Installation Complete!                  ║"
        echo "║                                                      ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo
        echo "VillageSQL ${CODEBASE} (${LATEST_VERSION}, ${DOCKER_ARCH}) is running via Docker on port ${PORT}"
        echo
        echo "Root Password: ${MYSQL_PASSWORD}"
        echo
        echo "To connect:"
        echo "  docker exec -it vsql mysql -u root -p"
        echo
        echo "To stop:"
        echo "  docker stop vsql"
        echo
        echo "To start again:"
        echo "  docker start vsql"
        echo
        echo "To view logs:"
        echo "  docker logs vsql"
        echo

        _send_event "Server Install Completed" ",\"method\":\"docker\",\"codebase\":\"${CODEBASE}\",\"arch\":\"${DOCKER_ARCH}\",\"version\":\"${LATEST_VERSION}\""
        exit 0
    fi

    # ─── Common Paths (prebuilt and source) ───
    INSTALL_BASE="${HOME}/.villagesql"
    DATA_DIR="${INSTALL_BASE}/data"
    VSQL_STAGE="preparing install directories"
    mkdir -p "${INSTALL_BASE}" "${DATA_DIR}"

    # ─── Prebuilt Install Path ───
    if [ "$INSTALL_METHOD" = "prebuilt" ]; then
        VSQL_STAGE="downloading prebuilt"
        echo "Installing prebuilt binary..."
        echo

        command -v tar >/dev/null 2>&1 || { echo "Error: 'tar' not found. Please install tar and try again."; exit 1; }

        _track "Server Install Started" ",\"method\":\"prebuilt\",\"codebase\":\"${CODEBASE}\",\"channel\":\"${VSQL_CHANNEL}\",\"platform\":\"${PREBUILT_PLATFORM}\""

        check_port

        PREBUILT_BASE="${INSTALL_BASE}/prebuilt"

        if [ -d "${PREBUILT_BASE}" ]; then
            IS_UPDATE=true
            echo "Existing installation found. Updating..."
        fi

        echo "Installation paths:"
        echo "  Install:    ${PREBUILT_BASE}"
        echo "  Data:       ${DATA_DIR}"
        echo

        echo "Downloading VillageSQL ${CODEBASE} ${PREBUILT_LABEL} (${PREBUILT_PLATFORM})..."
        TARBALL="${INSTALL_BASE}/vsql-server.tar.gz"
        curl -fsSL "${PREBUILT_URL}" -o "${TARBALL}" || { echo "Error: Download failed."; exit 1; }

        echo "Extracting..."
        EXTRACT_TMP=$(mktemp -d)
        VSQL_CLEANUP_DIR="${EXTRACT_TMP}"
        tar xzf "${TARBALL}" -C "${EXTRACT_TMP}" || {
            echo "Error: Extraction failed."
            rm -f "${TARBALL}"
            exit 1
        }
        rm -f "${TARBALL}"

        EXTRACTED=$(find "${EXTRACT_TMP}" -maxdepth 1 -mindepth 1 -type d | head -1)
        if [ -z "${EXTRACTED}" ]; then
            echo "Error: Unexpected package structure."
            exit 1
        fi

        rm -rf "${PREBUILT_BASE}"
        mv "${EXTRACTED}" "${PREBUILT_BASE}"
        rm -rf "${EXTRACT_TMP}"

        BUILD_DIR="${PREBUILT_BASE}"
        echo "✓ Prebuilt binary ready (${CODEBASE} ${PREBUILT_LABEL})"

        # Download and extract the Extension SDK. The SDK is codebase-agnostic
        # and only published on stable releases, so it always comes from
        # RELEASE_JSON even when the server binary came from nightly.
        SDK_RELEASES_URL="https://github.com/villagesql/villagesql-server/releases"
        SDK_URL=$(echo "$RELEASE_JSON" | grep '"browser_download_url"' | grep 'villagesql-extension-sdk-' | head -1 | sed 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/') || true
        if [ -n "${SDK_URL}" ]; then
            echo "Downloading Extension SDK..."
            SDK_TARBALL="${INSTALL_BASE}/vsql-sdk.tar.gz"
            if curl -fsSL "${SDK_URL}" -o "${SDK_TARBALL}"; then
                echo "Extracting Extension SDK..."
                SDK_EXTRACT_TMP=$(mktemp -d)
                if tar xzf "${SDK_TARBALL}" -C "${SDK_EXTRACT_TMP}"; then
                    rm -f "${SDK_TARBALL}"
                    SDK_EXTRACTED=$(find "${SDK_EXTRACT_TMP}" -maxdepth 1 -mindepth 1 -type d | head -1)
                    rm -rf "${PREBUILT_BASE}/$(basename "${SDK_EXTRACTED}")"
                    mv "${SDK_EXTRACTED}" "${PREBUILT_BASE}/"
                    echo "✓ Extension SDK ready"
                else
                    rm -f "${SDK_TARBALL}"
                    echo "Warning: SDK extraction failed. Download manually from:"
                    echo "  ${SDK_RELEASES_URL}"
                fi
                rm -rf "${SDK_EXTRACT_TMP}"
            else
                echo "Warning: SDK download failed. Download manually from:"
                echo "  ${SDK_RELEASES_URL}"
            fi
        else
            echo "Warning: Extension SDK not found in release assets. Download manually from:"
            echo "  ${SDK_RELEASES_URL}"
        fi
        echo
    fi

    # ─── Build from Source Path ───
    if [ "$INSTALL_METHOD" = "source" ]; then
        VSQL_STAGE="building from source"
        echo "Installing from source..."
        echo

        # ─── Source Ref Resolution ───
        # Map the chosen codebase and channel onto a git ref. Only the stable
        # channel has per-codebase tags (publish/<codebase>_<version>, resolved
        # against the current release rather than a hardcoded version).
        # nightly.latest and main are single shared refs, so a nightly or
        # latest build tracks whichever codebase those refs are cut from —
        # worth saying out loud, since the user just picked a codebase.
        SOURCE_VERSION="${VSQL_CHANNEL}"
        case "$VSQL_CHANNEL" in
            nightly)
                SOURCE_REF="nightly.latest"
                SOURCE_REF_LABEL="nightly"
                ;;
            latest)
                SOURCE_REF="main"
                SOURCE_REF_LABEL="latest (main)"
                ;;
            *)
                SOURCE_REF="publish/${CODEBASE}_${LATEST_VERSION}"
                SOURCE_REF_LABEL="${CODEBASE} ${LATEST_VERSION}"
                ;;
        esac

        if [ "$VSQL_CHANNEL" != "stable" ]; then
            echo "Note: ${SOURCE_REF} is a single shared branch — unlike stable, it is"
            echo "      not published per codebase, so this build may not be ${CODEBASE}."
            echo "      Choose Stable to build a specific codebase."
            echo
        fi

        # Check required tools
        echo "Checking dependencies..."
        command -v git >/dev/null 2>&1 || { echo "Error: 'git' not found. Please install git and try again."; exit 1; }
        command -v cmake >/dev/null 2>&1 || { echo "Error: 'cmake' not found. Please install cmake and try again."; exit 1; }
        command -v make >/dev/null 2>&1 || { echo "Error: 'make' not found. Please install build tools and try again."; exit 1; }

        # Per-codebase publish tags are newer than the tagging scheme itself, so
        # a release from before them has no publish/<codebase>_<version> tag.
        # Check the remote and fall back to the bare release tag instead of
        # letting the clone fail on a ref that was never cut.
        if [ "$VSQL_CHANNEL" = "stable" ] && \
           ! git ls-remote --exit-code --tags https://github.com/villagesql/villagesql-server.git "${SOURCE_REF}" >/dev/null 2>&1; then
            echo
            echo "Note: ${SOURCE_REF} is not published for release ${LATEST_VERSION};"
            echo "      building tag ${LATEST_TAG} instead."
            echo
            SOURCE_REF="${LATEST_TAG}"
            SOURCE_REF_LABEL="${LATEST_TAG}"
        fi

        # Check for platform-specific dependencies
        MISSING_DEPS=""

        if [ "${OS}" = "Linux" ]; then
            command -v pkg-config >/dev/null 2>&1 || MISSING_DEPS="${MISSING_DEPS} pkg-config"
            command -v bison >/dev/null 2>&1 || MISSING_DEPS="${MISSING_DEPS} bison"

            if [ ! -f /usr/include/openssl/ssl.h ] && [ ! -f /usr/local/include/openssl/ssl.h ]; then
                MISSING_DEPS="${MISSING_DEPS} libssl-dev"
            fi

            if [ -n "${MISSING_DEPS}" ]; then
                echo
                echo "Missing dependencies:${MISSING_DEPS}"
                echo
                echo "Please install them with:"
                echo "  sudo apt install bison build-essential cmake libaio-dev \\"
                echo "                   libncurses5-dev libssl-dev libtirpc-dev pkg-config \\"
                echo "                   rpcsvc-proto zlib1g-dev"
                echo
                exit 1
            fi
        elif [ "${OS}" = "Darwin" ]; then
            if ! command -v pkg-config >/dev/null 2>&1 && ! command -v pkgconf >/dev/null 2>&1; then
                MISSING_DEPS="${MISSING_DEPS} pkgconf"
            fi
            command -v bison >/dev/null 2>&1 || MISSING_DEPS="${MISSING_DEPS} bison"

            # Homebrew's unversioned `openssl` is now OpenSSL 4, which the
            # server does not build against, so the build needs openssl@3 by
            # name. Without this check the configure below falls back to
            # WITH_SSL=system and stops with "Not a supported openssl version"
            # after this function has already printed "Dependencies satisfied".
            if [ ! -d "/opt/homebrew/opt/openssl@3" ] && \
               [ ! -d "/usr/local/opt/openssl@3" ]; then
                MISSING_DEPS="${MISSING_DEPS} openssl@3"
            fi

            if [ -n "${MISSING_DEPS}" ]; then
                echo
                echo "Missing dependencies:${MISSING_DEPS}"
                echo
                echo "Please install them with:"
                echo "  brew install bison cmake openssl@3 pkgconf"
                echo
                exit 1
            fi
        fi

        echo "✓ Dependencies satisfied"
        _track "Server Install Started" ",\"method\":\"source\",\"codebase\":\"${CODEBASE}\",\"source_version\":\"${SOURCE_VERSION}\""
        echo

        check_port

        REPO_DIR="${INSTALL_BASE}/source"
        BUILD_DIR="${INSTALL_BASE}/build"

        echo "Installation paths:"
        echo "  Source:     ${REPO_DIR}"
        echo "  Build:      ${BUILD_DIR}"
        echo "  Data:       ${DATA_DIR}"
        echo

        # Clone or update repository
        if [ -d "${REPO_DIR}/.git" ]; then
            IS_UPDATE=true
            echo "Repository already exists. Updating to ${SOURCE_REF_LABEL}..."
            cd "${REPO_DIR}"
            git clean -fd >/dev/null 2>&1
            git fetch --depth 1 origin "${SOURCE_REF}" 2>&1 || { echo "Error: Failed to update repository"; exit 1; }
            git checkout -f FETCH_HEAD 2>&1 || { echo "Error: Failed to checkout ${SOURCE_REF_LABEL}"; exit 1; }
        else
            echo "Cloning VillageSQL repository (${SOURCE_REF_LABEL})..."
            git clone --depth 1 --branch "${SOURCE_REF}" https://github.com/villagesql/villagesql-server.git "${REPO_DIR}" 2>&1 || { echo "Error: Failed to clone repository"; exit 1; }
        fi

        echo "✓ Repository ready (${SOURCE_REF_LABEL})"
        echo

        # Build
        echo "Building VillageSQL (this may take 10-30 minutes)..."
        JOBS=$(($(getconf _NPROCESSORS_ONLN) - 1))
        if [ $JOBS -lt 1 ]; then
            JOBS=1
        fi
        echo "Using ${JOBS} CPU cores for parallel build..."
        echo

        # A CMakeCache from a different codebase poisons the configure: many of
        # these values (WITH_CURL among them) are cache-sticky, so a build dir
        # last configured for mysql-* silently keeps those settings when
        # reconfigured for percona-8.4. Stamp the codebase and wipe on a change.
        CODEBASE_STAMP="${BUILD_DIR}/.vsql_codebase"
        if [ -f "${BUILD_DIR}/CMakeCache.txt" ] && \
           [ "$(cat "${CODEBASE_STAMP}" 2>/dev/null)" != "${CODEBASE}" ]; then
            echo "Build directory was configured for a different codebase; starting clean..."
            rm -rf "${BUILD_DIR}"
        fi

        mkdir -p "${BUILD_DIR}"
        echo "${CODEBASE}" > "${CODEBASE_STAMP}"
        cd "${BUILD_DIR}"

        # Configure with CMake
        echo "Configuring build with CMake..."

        # Set OpenSSL path based on OS
        if [ "${OS}" = "Darwin" ]; then
            # macOS - check for Homebrew OpenSSL
            if [ -d "/opt/homebrew/opt/openssl@3" ]; then
                SSL_PATH="/opt/homebrew/opt/openssl@3"
            elif [ -d "/usr/local/opt/openssl@3" ]; then
                SSL_PATH="/usr/local/opt/openssl@3"
            else
                SSL_PATH="system"
            fi
        else
            # Linux
            SSL_PATH="system"
        fi

        # The Percona fork needs four flags MySQL builds do not, matching
        # villagesql/bld_tools/build_ci.sh on the percona branch:
        #   WITH_CURL=system  keyring_vault is a FATAL_ERROR without CURL, and
        #                     WITH_CURL defaults to "none".
        #   the other three   Percona's .gitmodules declares rocksdb,
        #                     coredumper and libkmip submodules that are not
        #                     vendored, and all three features default ON, so
        #                     configure fails hunting for sources that were
        #                     never checked out.
        PERCONA_FLAGS=""
        if [ "${CODEBASE}" = "percona-8.4" ]; then
            PERCONA_FLAGS="-DWITH_CURL=system -DWITH_ROCKSDB=0 -DWITH_COREDUMPER=OFF -DWITHOUT_COMPONENT_KEYRING_KMIP=ON"
        fi

        cmake "${REPO_DIR}" -DWITH_DEBUG=1 -DWITH_SSL="${SSL_PATH}" -DDOWNLOAD_BOOST=1 ${PERCONA_FLAGS} > "${BUILD_DIR}/cmake.log" 2>&1 || {
            echo "Error: CMake configuration failed. Check ${BUILD_DIR}/cmake.log for details"
            tail -30 "${BUILD_DIR}/cmake.log"
            exit 1
        }

        # Build with progress indicator
        echo "Compiling (please be patient)..."
        echo "This will take 10-30 minutes..."
        echo

        # Start build in background and show progress
        make -j${JOBS} > "${BUILD_DIR}/build.log" 2>&1 &
        MAKE_PID=$!

        # Show progress while build is running
        printf "Building: "
        while kill -0 $MAKE_PID 2>/dev/null; do
            sleep 1
            printf "#"
        done
        echo

        # Wait for make to complete and check exit status
        wait $MAKE_PID
        BUILD_EXIT=$?

        if [ $BUILD_EXIT -ne 0 ]; then
            echo "Error: Build failed. Check ${BUILD_DIR}/build.log for details"
            tail -50 "${BUILD_DIR}/build.log"
            exit 1
        fi

        if [ ! -f "${BUILD_DIR}/bin/mysqld" ]; then
            echo "Error: Build failed. mysqld binary not found."
            exit 1
        fi

        echo "✓ Build complete"
        echo

        # Build bundled extensions
        echo "Building bundled extensions..."
        EXT_DIR="${INSTALL_BASE}/extensions"
        mkdir -p "${EXT_DIR}"

        EXTENSIONS_LIST="$REPO_DIR/villagesql/dev_server/bundled_extensions.txt"
        CORE_EXTENSIONS=$(readBundledExtensions "${EXTENSIONS_LIST}")
        if [ -z "$CORE_EXTENSIONS" ]; then
            # Fallback list
            CORE_EXTENSIONS="vsql-uuid vsql-ai vsql-network-address vsql-crypto vsql-http"
        fi
        EXT_FAILED=""
        echo "Extensions to build ${CORE_EXTENSIONS}"

        for EXT_NAME in ${CORE_EXTENSIONS}; do
            EXT_SRC="${EXT_DIR}/${EXT_NAME}"
            EXT_BUILD="${EXT_SRC}/build"

            EXT_KEY="https://github.com/villagesql/${EXT_NAME}"
            EXT_URL="${EXT_KEY}.git"
            EXT_BUILD="${EXT_SRC}/build"

            EXT_REF=""
            if [ -f "${EXTENSIONS_LIST}" ]; then
                EXT_REF=$(grep -e "^${EXT_KEY} " "${EXTENSIONS_LIST}" | cut -d' ' -f2 || echo "")
                if [ -n "${EXT_REF}" ]; then
                    echo "  ${EXT_NAME} (${EXT_REF})... "
                else
                    echo "  ${EXT_NAME}... "
                fi
            else
                echo "  ${EXT_NAME}... "
            fi

            # Clone or update extension repo
            if [ -d "${EXT_SRC}/.git" ]; then
                cd "${EXT_SRC}"
                CLONE_OK=true
                git clean -fd >/dev/null 2>&1 || CLONE_OK=false
                if [ -n "${EXT_REF}" ]; then
                    git fetch --depth 1 origin "${EXT_REF}" >/dev/null 2>&1 || CLONE_OK=false
                else
                    git fetch --depth 1 >/dev/null 2>&1 || CLONE_OK=false
                fi
                git checkout -f FETCH_HEAD >/dev/null 2>&1 || CLONE_OK=false
                if [ "$CLONE_OK" = false ]; then
                    echo "FAILED (clone)"
                    EXT_FAILED="${EXT_FAILED} ${EXT_NAME}"
                    continue
                fi
            else
                if [ -n "${EXT_REF}" ]; then
                    git clone --depth 1 --branch "${EXT_REF}" "${EXT_URL}" "${EXT_SRC}" >/dev/null 2>&1
                else
                    git clone --depth 1 "${EXT_URL}" "${EXT_SRC}" >/dev/null 2>&1
                fi

                if [ $? -ne 0 ]; then
                    echo "FAILED (clone)"
                    EXT_FAILED="${EXT_FAILED} ${EXT_NAME}"
                    continue
                fi
            fi

            # Build extension
            mkdir -p "${EXT_BUILD}"
            cd "${EXT_BUILD}"

            if cmake .. -DVillageSQL_BUILD_DIR="${BUILD_DIR}" > "${EXT_BUILD}/build.log" 2>&1 && \
                make -j${JOBS} >> "${EXT_BUILD}/build.log" 2>&1 && \
                make install >> "${EXT_BUILD}/build.log" 2>&1; then
                echo "✓"
            else
                echo "FAILED (build — see ${EXT_BUILD}/build.log)"
                EXT_FAILED="${EXT_FAILED} ${EXT_NAME}"
            fi
        done

        if [ -n "${EXT_FAILED}" ]; then
            echo
            echo "Warning: Some extensions failed to build:${EXT_FAILED}"
            echo "You can build them manually later."
        else
            echo "✓ All bundled extensions built and installed"
        fi
        echo

        cd "${BUILD_DIR}"
    fi

    # ─── Shared: DB Init, Shortcuts, Credentials, Start Server ───
    VSQL_STAGE="initializing database"
    # Both prebuilt and source paths converge here with BUILD_DIR set.

    # Initialize database if needed
    if [ ! -d "${DATA_DIR}/mysql" ]; then
        echo "Initializing database..."
        "${BUILD_DIR}/bin/mysqld" --initialize-insecure --datadir="${DATA_DIR}" --basedir="${BUILD_DIR}" 2>&1 | tail -5
        echo "✓ Database initialized"

        # Generate random password (alphanumeric only to avoid shell escaping issues)
        MYSQL_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

        # Start server temporarily to set password
        echo "Setting up root password..."
        printf "Starting server"
        # A failure here used to fall straight through to the ALTER USER, which
        # then failed silently and left an install with an unknown password.
        if ! start_mysqld || ! wait_for_server 30; then
            echo
            server_start_failed "initializing the root password"
            exit 1
        fi
        echo " ✓"

        # Set root password
        "${BUILD_DIR}/bin/mysql" --socket="${INSTALL_BASE}/mysql.sock" -u root << EOSQL 2>/dev/null
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
FLUSH PRIVILEGES;
EOSQL

        # Shutdown temporary server
        "${BUILD_DIR}/bin/mysqladmin" --socket="${INSTALL_BASE}/mysql.sock" -u root -p"${MYSQL_PASSWORD}" shutdown 2>/dev/null
        sleep 2
    else
        echo "Database already initialized"
        echo "Using existing database - password not changed"

        # Try to read existing password from credentials file
        if [ -f "${INSTALL_BASE}/credentials.txt" ]; then
            MYSQL_PASSWORD=$(grep "Root Password:" "${INSTALL_BASE}/credentials.txt" | cut -d' ' -f3)
            if [ -z "$MYSQL_PASSWORD" ]; then
                MYSQL_PASSWORD="<check ${INSTALL_BASE}/credentials.txt>"
            fi
        else
            MYSQL_PASSWORD="<password not found - check ${INSTALL_BASE}/credentials.txt>"
        fi
    fi
    echo

    # Create shortcuts in ~/.local/bin if it exists
    LOCALBIN="${HOME}/.local/bin"
    if [ -d "${LOCALBIN}" ] && [ -w "${LOCALBIN}" ]; then
        ln -sf "${BUILD_DIR}/bin/mysql" "${LOCALBIN}/villagesql"
        ln -sf "${BUILD_DIR}/bin/mysqld" "${LOCALBIN}/villagesql-server"
        ln -sf "${BUILD_DIR}/bin/mysqladmin" "${LOCALBIN}/villagesql-admin"
        echo "✓ Created shortcuts in ${LOCALBIN}/"
        SHORTCUTS_CREATED=true
    else
        SHORTCUTS_CREATED=false
    fi
    echo

    # Save credentials
    cat > "${INSTALL_BASE}/credentials.txt" << EOF
VillageSQL Installation Complete
================================

Codebase:      ${CODEBASE}
Version:       ${VSQL_CHANNEL} (${SOURCE_REF_LABEL:-${PREBUILT_LABEL}})
Install Method: ${INSTALL_METHOD}

Installation:  ${INSTALL_BASE}
Source Dir:    ${REPO_DIR:-N/A}
Build Dir:     ${BUILD_DIR}
Data Dir:      ${DATA_DIR}
Port:          ${PORT}
Socket:        ${INSTALL_BASE}/mysql.sock
Log:           ${INSTALL_BASE}/mysql.log

Root Password: ${MYSQL_PASSWORD}

IMPORTANT: Port ${PORT} must be available to start the server.
If you have another MySQL instance running, stop it first:
  brew services stop mysql    # Homebrew
  sudo systemctl stop mysql   # Linux systemd

Start Server:
  ${BUILD_DIR}/bin/mysqld --datadir=${INSTALL_BASE}/data --socket=${INSTALL_BASE}/mysql.sock --port=${PORT} --pid-file=${INSTALL_BASE}/mysql.pid --log-error=${INSTALL_BASE}/mysql.log --vsql_allow_preview_extensions=ON --daemonize

Connect:
  ${BUILD_DIR}/bin/mysql -u root -p --socket=${INSTALL_BASE}/mysql.sock

Stop Server:
  ${BUILD_DIR}/bin/mysqladmin --socket=${INSTALL_BASE}/mysql.sock -u root -p shutdown

Shortcuts:
  villagesql        → MySQL client
  villagesql-server → MySQL server
  villagesql-admin  → MySQL admin tool

Direct Paths:
  MySQL Client:  ${BUILD_DIR}/bin/mysql
  MySQL Server:  ${BUILD_DIR}/bin/mysqld
  MySQL Admin:   ${BUILD_DIR}/bin/mysqladmin

EOF

    if [ "$SHORTCUTS_CREATED" = false ]; then
        cat >> "${INSTALL_BASE}/credentials.txt" << EOF
Add to PATH for shortcuts:
  export PATH="\$HOME/.local/bin:\$PATH"
  (Create ${LOCALBIN} first if it doesn't exist)

EOF
    fi

    chmod 600 "${INSTALL_BASE}/credentials.txt"

    # Success message
    echo
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║                                                      ║"
    echo "║            ✓ Installation Complete!                  ║"
    echo "║                                                      ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo
    echo "VillageSQL has been installed to: ${INSTALL_BASE}"
    echo
    echo "Root Password: ${MYSQL_PASSWORD}"
    echo
    echo "Starting VillageSQL server..."
    echo

    # Start the server. start_mysqld can fail outright (bad option, missing
    # library) or return 0 and die during startup, so both are checked.
    SERVER_UP=true
    printf "Waiting for the server"
    if ! start_mysqld || ! wait_for_server 30; then
        SERVER_UP=false
    fi
    echo

    if [ "${SERVER_UP}" = true ]; then
        echo "✓ VillageSQL server is running on port ${PORT}"
        echo
        echo "Credentials saved to: ${INSTALL_BASE}/credentials.txt"
        echo
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║                                                      ║"
        echo "║                 Ready to Connect!                    ║"
        echo "║                                                      ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo
        echo "To connect to VillageSQL, run:"
        echo "  ${BUILD_DIR}/bin/mysql -u root -p --socket=${INSTALL_BASE}/mysql.sock"
        echo
        echo "Root password: ${MYSQL_PASSWORD}"
        echo
        echo "To stop the server:"
        echo "  ${BUILD_DIR}/bin/mysqladmin --socket=${INSTALL_BASE}/mysql.sock -u root -p shutdown"
        echo
    else
        server_start_failed "starting the installed server"
        echo "Credentials saved to: ${INSTALL_BASE}/credentials.txt"
        echo
        echo "Root password: ${MYSQL_PASSWORD}"
        echo
        echo "Once the problem above is fixed, start the server with:"
        echo "  ${BUILD_DIR}/bin/mysqld --datadir=${INSTALL_BASE}/data --socket=${INSTALL_BASE}/mysql.sock --port=${PORT} --pid-file=${INSTALL_BASE}/mysql.pid --log-error=${INSTALL_BASE}/mysql.log --vsql_allow_preview_extensions=ON --daemonize"
        echo
        echo "Then connect with:"
        echo "  ${BUILD_DIR}/bin/mysql -u root -p --socket=${INSTALL_BASE}/mysql.sock"
        echo
        exit 1
    fi

    # Foreground, not _track: `exit 0` follows immediately, and a container
    # stops the moment its main process exits, killing a backgrounded curl.
    if [ "$INSTALL_METHOD" = "prebuilt" ]; then
        _send_event "Server Install Completed" ",\"method\":\"prebuilt\",\"codebase\":\"${CODEBASE}\",\"channel\":\"${VSQL_CHANNEL}\",\"is_update\":${IS_UPDATE},\"shortcuts_created\":${SHORTCUTS_CREATED},\"version\":\"${PREBUILT_LABEL}\""
    else
        _send_event "Server Install Completed" ",\"method\":\"source\",\"codebase\":\"${CODEBASE}\",\"is_update\":${IS_UPDATE},\"shortcuts_created\":${SHORTCUTS_CREATED},\"source_version\":\"${SOURCE_VERSION}\""
    fi
    exit 0
}

main
