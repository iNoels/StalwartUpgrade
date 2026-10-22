#!/usr/bin/env bash
#
# stalwart-upgrade.sh -- interactive upgrade / downgrade of a Stalwart binary
# that was installed with the official install.sh.
#
# Supported service managers (same as install.sh):
#   Linux systemd, Linux init.d, macOS launchd, FreeBSD rc.d
# Installs under a custom PREFIX are found via the service definition.
#
# - detects architecture, binary path (service definition vs. `which`) and version
# - lists newer / older releases from GitHub and lets you pick one
# - shows the release notes of every version in between before installing
# - optionally verifies the download with cosign (sigstore bundle)
# - does NOT keep a backup of the old binary (use your backups / GitHub)
#

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] \
    || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "This script needs bash >= 4.3 (found ${BASH_VERSION:-none})." >&2
    echo "macOS: brew install bash, then run: sudo \"\$(brew --prefix)/bin/bash\" $0" >&2
    exit 1
fi

set -euo pipefail

readonly REPO="stalwartlabs/stalwart"
readonly API_URL="https://api.github.com/repos/${REPO}/releases"
readonly DOWNLOAD_URL="https://github.com/${REPO}/releases/download"
readonly NOTES_PATTERN='breaking|migrat|upgrad|important|warning|deprecat|incompatib|manual'
readonly DOWNGRADE_LIST_LIMIT=15

SERVICE="stalwart"
COMPONENT=""
INCLUDE_PRERELEASE=false
DRY_RUN=false
VERIFY=true

OS=""          # linux | macos | freebsd
SVC_TYPE=""    # systemd | initd | launchd | rcd
SVC_FILE=""    # unit file, init script, plist or rc script
SVC_LABEL=""   # launchd label

TMP_DIR=""
STAGED_FILE=""
RELEASES_JSON=""
ARCH=""
BIN=""
CURRENT=""
ASSET=""
CHOSEN=""
declare -a VERSIONS=()
declare -A TAG_OF=()
declare -A DATE_OF=()

if [[ -t 1 ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_BOLD="" C_RESET=""
fi

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_BOLD}$*${C_RESET}"; }
ok()   { printf '%s\n' "${C_GREEN}✔ $*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}⚠ $*${C_RESET}" >&2; }
err()  { printf '%s\n' "${C_RED}✖ $*${C_RESET}" >&2; exit 1; }

check_cmd() { command -v "$1" > /dev/null 2>&1; }

need_cmd() {
    local _cmd
    local -a _missing=()

    for _cmd in "$@"; do
        check_cmd "$_cmd" || _missing+=("$_cmd")
    done

    (( ${#_missing[@]} == 0 )) && return 0
    install_packages "${_missing[@]}"
}

# Offers to install missing commands via the system package manager.
install_packages() {
    local -a _install
    if   check_cmd apt-get; then _install=(apt-get install -y)
    elif check_cmd dnf;     then _install=(dnf install -y)
    elif check_cmd yum;     then _install=(yum install -y)
    elif check_cmd zypper;  then _install=(zypper --non-interactive install)
    elif check_cmd pacman;  then _install=(pacman -S --noconfirm)
    elif check_cmd apk;     then _install=(apk add)
    elif check_cmd pkg;     then _install=(pkg install -y)
    elif check_cmd brew;    then err "Missing command(s): $* -- run 'brew install $*' as your normal user."
    else err "Missing command(s): $* -- please install them."
    fi

    warn "Missing command(s): $*"
    confirm "Install them now with '${_install[*]} $*'?" y \
        || err "Missing command(s): $*"
    "${_install[@]}" "$@" || err "Installing $* failed."

    local _cmd
    for _cmd in "$@"; do
        check_cmd "$_cmd" || err "'${_cmd}' still not found after installing."
    done
}

# confirm "question" [default y|n]
confirm() {
    local _default="${2:-n}" _hint _answer
    if [[ "$_default" == y ]]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
    read -r -p "$1 ${_hint} " _answer || true
    _answer="${_answer:-$_default}"
    [[ "$_answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ver_gt A B -> true if A > B (version sort)
ver_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

cleanup() {
    [[ -n "$STAGED_FILE" && -e "$STAGED_FILE" ]] && rm -f "$STAGED_FILE"
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    return 0
}

print_usage() {
    cat <<'EOF'
Usage: stalwart-upgrade.sh [options]

Interactive upgrade / downgrade of Stalwart installed with install.sh
(Linux systemd / init.d, macOS launchd, FreeBSD rc.d, any PREFIX).

Options:
  --fdb                 Use the FoundationDB build (auto-detected otherwise).
  --service NAME        Service name (default: stalwart).
  --include-prerelease  Also offer pre-releases.
  --no-verify           Skip the cosign signature check.
  --dry-run             Do everything except stopping/replacing/starting.
  -h, --help            Show this help.

Environment:
  GITHUB_TOKEN          Optional token to avoid GitHub API rate limits.
EOF
}

# --------------------------------------------------------------------------
# detection
# --------------------------------------------------------------------------

detect_os() {
    local _uname
    _uname="$(uname -s)"
    case "$_uname" in
        Linux)   OS="linux" ;;
        Darwin)  OS="macos" ;;
        FreeBSD) OS="freebsd" ;;
        *) err "Unsupported OS: ${_uname}" ;;
    esac
}

detect_arch() {
    local _cpu
    _cpu="$(uname -m)"

    case "$OS" in
        macos)
            # under Rosetta, uname -m reports x86_64 on Apple Silicon
            if [[ "$_cpu" == x86_64 && "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == 1 ]]; then
                _cpu="arm64"
            fi
            case "$_cpu" in
                arm64 | aarch64) ARCH="aarch64-apple-darwin" ;;
                x86_64)          ARCH="x86_64-apple-darwin" ;;
                *) err "Unsupported CPU type: ${_cpu}" ;;
            esac
            ;;
        freebsd)
            case "$_cpu" in
                amd64 | x86_64) ARCH="x86_64-unknown-freebsd" ;;
                *) err "Unsupported CPU type: ${_cpu} (Stalwart only ships x86_64 builds for FreeBSD)" ;;
            esac
            ;;
        linux)
            detect_arch_linux "$_cpu"
            ;;
    esac
}

detect_arch_linux() {
    local _cpu="$1" _libc="gnu" _suffix="" _ldd _features

    _ldd="$(ldd --version 2>&1 || true)"
    [[ "$_ldd" == *musl* ]] && _libc="musl"

    case "$_cpu" in
        x86_64 | x86-64 | x64 | amd64) _cpu="x86_64" ;;
        aarch64 | arm64)               _cpu="aarch64" ;;
        armv7l | armv8l)               _cpu="armv7"; _suffix="eabihf" ;;
        armv6l | arm | xscale)         _cpu="arm";   _suffix="eabihf" ;;
        *) err "Unsupported CPU type: ${_cpu}" ;;
    esac

    # 64-bit kernel with 32-bit userland
    if [[ "$_cpu" == aarch64 && "$(getconf LONG_BIT 2>/dev/null || echo 64)" == 32 ]]; then
        _cpu="armv7"; _suffix="eabihf"
    fi

    # armv7 without NEON -> fall back to arm
    if [[ "$_cpu" == armv7 ]]; then
        _features="$(grep '^Features' /proc/cpuinfo 2>/dev/null || true)"
        if [[ -n "$_features" && "$_features" != *neon* ]]; then
            _cpu="arm"
        fi
    fi

    ARCH="${_cpu}-unknown-linux-${_libc}${_suffix}"
}

# --------------------------------------------------------------------------
# service manager (same service types as install.sh)
# --------------------------------------------------------------------------

detect_service() {
    case "$OS" in
        linux)
            if check_cmd systemctl && systemctl cat "$SERVICE" > /dev/null 2>&1; then
                SVC_TYPE="systemd"
                SVC_FILE="$(systemctl show -p FragmentPath --value "$SERVICE" 2>/dev/null || true)"
            elif [[ -f "/etc/init.d/${SERVICE}" ]]; then
                SVC_TYPE="initd"
                SVC_FILE="/etc/init.d/${SERVICE}"
            fi
            ;;
        macos)
            SVC_FILE="/Library/LaunchDaemons/${SERVICE}.plist"
            if [[ -f "$SVC_FILE" ]]; then
                SVC_TYPE="launchd"
                SVC_LABEL="$(plutil -extract Label raw -o - "$SVC_FILE" 2>/dev/null || printf '%s' "$SERVICE")"
            fi
            ;;
        freebsd)
            SVC_FILE="/usr/local/etc/rc.d/${SERVICE}"
            if [[ -f "$SVC_FILE" ]]; then
                SVC_TYPE="rcd"
            fi
            ;;
    esac
    [[ -n "$SVC_TYPE" ]] || err "No '${SERVICE}' service found on ${OS} (use --service NAME)."
}

# Prints the binary path the service starts.
service_exec_path() {
    local _line _path="" _key _i _arg _args="" _re='exec "([^"]+)"'

    case "$SVC_TYPE" in
        systemd)
            # including drop-ins; the last non-empty ExecStart= wins
            while IFS= read -r _line; do
                [[ "$_line" =~ ^[[:space:]]*ExecStart=(.*)$ ]] || continue
                _line="${BASH_REMATCH[1]}"
                [[ -z "$_line" ]] && continue
                _line="${_line#"${_line%%[![:space:]]*}"}"
                # strip systemd exec prefixes (-, @, +, !, :)
                while [[ "$_line" == [-@+!:]* ]]; do _line="${_line:1}"; done
                _path="${_line%% *}"
            done < <(systemctl cat "$SERVICE" 2>/dev/null)
            ;;
        initd | rcd)
            # init.d: DAEMON=/path   rc.d: procname="/path"
            if [[ "$SVC_TYPE" == initd ]]; then _key="DAEMON"; else _key="procname"; fi
            while IFS= read -r _line; do
                [[ "$_line" == "${_key}="* ]] || continue
                _line="${_line#*=}"
                _line="${_line//\"/}"
                _line="${_line//\'/}"
                _path="${_line%% *}"
            done < "$SVC_FILE"
            ;;
        launchd)
            # ProgramArguments: /bin/sh -c '... exec "/path" --config=...'
            for _i in 0 1 2 3 4 5; do
                _arg="$(plutil -extract "ProgramArguments.${_i}" raw -o - "$SVC_FILE" 2>/dev/null)" || break
                _args+="${_arg}"$'\n'
            done
            if [[ "$_args" =~ $_re ]]; then
                _path="${BASH_REMATCH[1]}"
            elif [[ "${_args%%$'\n'*}" != */sh ]]; then
                _path="${_args%%$'\n'*}"
            fi
            ;;
    esac
    printf '%s' "$_path"
}

svc_stop() {
    case "$SVC_TYPE" in
        systemd)     systemctl stop "$SERVICE" ;;
        initd | rcd) service "$SERVICE" stop ;;
        launchd)     launchctl bootout "system/${SVC_LABEL}" ;;
    esac
}

svc_start() {
    case "$SVC_TYPE" in
        systemd)     systemctl start "$SERVICE" ;;
        initd | rcd) service "$SERVICE" start ;;
        launchd)     launchctl bootstrap system "$SVC_FILE" ;;
    esac
}

svc_is_active() {
    local _out
    case "$SVC_TYPE" in
        systemd)
            [[ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" == active ]]
            ;;
        initd | rcd)
            service "$SERVICE" status > /dev/null 2>&1
            ;;
        launchd)
            _out="$(launchctl print "system/${SVC_LABEL}" 2>/dev/null || true)"
            [[ "$_out" == *"state = running"* ]]
            ;;
    esac
}

# Shows service manager and Stalwart log output since $1 (local time,
# YYYY-mm-dd HH:MM:SS) / $2 (UTC, YYYY-mm-ddTHH:MM:SS).
svc_show_logs() {
    local _since="$1" _since_utc="$2" _dir _log=""

    if [[ "$SVC_TYPE" == systemd ]]; then
        journalctl -u "$SERVICE" --since "$_since" -n 50 --no-pager 2>/dev/null || true
    fi

    # install.sh: <PREFIX>/logs or /var/log/stalwart
    for _dir in "$(dirname "$(dirname "$BIN")")/logs" /var/log/stalwart; do
        [[ -d "$_dir" ]] || continue
        _log="$(ls -t "$_dir"/* 2>/dev/null | head -n 1 || true)"
        [[ -n "$_log" ]] && break
    done
    if [[ -n "$_log" && -f "$_log" ]]; then
        say ""
        info "${_log} since the restart:"
        # Stalwart log lines start with an ISO UTC timestamp
        awk -v s="$_since_utc" 'p || substr($1, 1, 19) >= s { p = 1; print }' "$_log" \
            | tail -n 40 || true
    fi
}

detect_binary_path() {
    local _svc_path _which_path _svc_real _which_real

    _svc_path="$(service_exec_path)"
    [[ -n "$_svc_path" ]] || err "Could not read the binary path from ${SVC_FILE}."

    if check_cmd which; then
        _which_path="$(which stalwart 2>/dev/null || true)"
    else
        _which_path="$(command -v stalwart 2>/dev/null || true)"
    fi

    say "  Service type    : ${SVC_TYPE}"
    say "  Service file    : ${SVC_FILE:-?}"
    say "  Service binary  : ${_svc_path}"
    say "  which stalwart  : ${_which_path:-<not in PATH>}"

    _svc_real="$(readlink -f "$_svc_path" 2>/dev/null || printf '%s' "$_svc_path")"
    BIN="$_svc_path"

    if [[ -z "$_which_path" ]]; then
        warn "'stalwart' is not in PATH -- using the path from the service file."
    else
        _which_real="$(readlink -f "$_which_path" 2>/dev/null || printf '%s' "$_which_path")"
        if [[ "$_svc_real" == "$_which_real" ]]; then
            ok "Service file and 'which' point to the same binary."
        else
            warn "Service file and 'which' point to DIFFERENT binaries:"
            warn "    service: ${_svc_real}"
            warn "    which  : ${_which_real}"
            warn "The service runs the first one."
            if ! confirm "Use the binary from the service file (${_svc_path})?" y; then
                BIN="$_which_path"
            fi
        fi
    fi

    [[ -f "$BIN" ]] || err "Binary '${BIN}' does not exist."
    [[ -x "$BIN" ]] || err "Binary '${BIN}' is not executable."
    BIN="$(readlink -f "$BIN")"
}

# Prints the version reported by a stalwart binary, or nothing.
binary_version() {
    local _out=""
    _out="$("$1" --version 2>&1 || true)"
    if [[ ! "$_out" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
        _out="$("$1" -V 2>&1 || true)"
    fi
    if [[ "$_out" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

detect_current_version() {
    CURRENT="$(binary_version "$BIN")"
    if [[ -z "$CURRENT" ]]; then
        warn "Could not determine the version of ${BIN}."
        read -r -p "Enter the currently installed version (e.g. 0.16.26): " CURRENT
        CURRENT="${CURRENT#v}"
        [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || err "Invalid version: ${CURRENT}"
    fi
}

detect_component() {
    local _libs
    if [[ -z "$COMPONENT" ]]; then
        COMPONENT="stalwart"
        # FoundationDB builds exist for Linux only
        if [[ "$OS" == linux ]]; then
            _libs="$(ldd "$BIN" 2>&1 || true)"
            [[ "$_libs" == *libfdb_c* ]] && COMPONENT="stalwart-foundationdb"
        fi
    fi
    ASSET="${COMPONENT}-${ARCH}.tar.gz"
}

# --------------------------------------------------------------------------
# GitHub releases
# --------------------------------------------------------------------------

github_get() {
    local -a _hdr=(-H "Accept: application/vnd.github+json")
    [[ -n "${GITHUB_TOKEN:-}" ]] && _hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "${_hdr[@]}" "$1"
}

fetch_releases() {
    local _page _file _count _tag _date _ver
    local -a _pages=()

    for _page in 1 2 3; do
        _file="${TMP_DIR}/releases-${_page}.json"
        github_get "${API_URL}?per_page=100&page=${_page}" > "$_file" \
            || err "Could not fetch releases from GitHub (rate limit? set GITHUB_TOKEN)."
        _pages+=("$_file")
        _count="$(jq 'length' "$_file")"
        (( _count < 100 )) && break
    done

    RELEASES_JSON="${TMP_DIR}/releases.json"
    jq -s 'add' "${_pages[@]}" > "$RELEASES_JSON"

    while IFS=$'\t' read -r _tag _date; do
        _ver="${_tag#v}"
        [[ "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || continue
        TAG_OF["$_ver"]="$_tag"
        DATE_OF["$_ver"]="${_date:0:10}"
    done < <(jq -r --arg asset "$ASSET" --argjson pre "$INCLUDE_PRERELEASE" '
        .[]
        | select(.draft | not)
        | select($pre or (.prerelease | not))
        | select(any(.assets[]?; .name == $asset))
        | [.tag_name, (.published_at // "")] | @tsv' "$RELEASES_JSON")

    (( ${#TAG_OF[@]} > 0 )) || err "No releases found that provide ${ASSET}."
    mapfile -t VERSIONS < <(printf '%s\n' "${!TAG_OF[@]}" | sort -V)
}

release_field() {
    jq -r --arg t "$1" --arg f "$2" '.[] | select(.tag_name == $t) | .[$f] // ""' "$RELEASES_JSON"
}

versions_newer() {
    local _v
    for _v in "${VERSIONS[@]}"; do ver_gt "$_v" "$CURRENT" && printf '%s\n' "$_v"; done
    return 0
}

versions_older() {
    local _v
    for _v in "${VERSIONS[@]}"; do ver_gt "$CURRENT" "$_v" && printf '%s\n' "$_v"; done
    return 0
}

# --------------------------------------------------------------------------
# menus
# --------------------------------------------------------------------------

# choose_version "title" [limit] versions... -> sets CHOSEN (empty = back)
choose_version() {
    local _title="$1" _limit="$2" _answer _i _latest="${VERSIONS[-1]}"
    shift 2
    local -a _list=("$@") _shown

    CHOSEN=""
    while true; do
        _shown=("${_list[@]}")
        if [[ "$_limit" -gt 0 && ${#_list[@]} -gt "$_limit" ]]; then
            _shown=("${_list[@]:0:$_limit}")
        fi

        say ""
        info "$_title"
        for _i in "${!_shown[@]}"; do
            printf '  %2d) %-14s %s%s\n' "$((_i + 1))" "${_shown[$_i]}" \
                "${DATE_OF[${_shown[$_i]}]}" \
                "$([[ "${_shown[$_i]}" == "$_latest" ]] && printf '  (latest)')"
        done
        [[ ${#_shown[@]} -lt ${#_list[@]} ]] && say "   a) show all ${#_list[@]} versions"
        say "   b) back"

        read -r -p "Select: " _answer || return 0
        case "$_answer" in
            b | B | "") return 0 ;;
            a | A) _limit=0 ;;
            *)
                if [[ "$_answer" =~ ^[0-9]+$ ]] && (( _answer >= 1 && _answer <= ${#_shown[@]} )); then
                    CHOSEN="${_shown[$((_answer - 1))]}"
                    return 0
                fi
                warn "Invalid selection."
                ;;
        esac
    done
}

# Shows release notes for the given versions (in the given order).
show_release_notes() {
    local _file="${TMP_DIR}/notes.txt" _v _tag _body _hits=""
    : > "$_file"

    for _v in "$@"; do
        _tag="${TAG_OF[$_v]}"
        _body="$(release_field "$_tag" body | tr -d '\r')"
        {
            printf '%s\n' "================================================================"
            printf ' %s  (%s)\n' "$_tag" "${DATE_OF[$_v]}"
            printf ' https://github.com/%s/releases/tag/%s\n' "$REPO" "$_tag"
            printf '%s\n\n' "================================================================"
            printf '%s\n\n' "${_body:-<no release notes>}"
        } >> "$_file"
        _hits+="$(grep -iE "$NOTES_PATTERN" <<< "$_body" | sed "s/^/  [${_tag}] /" || true)"
        [[ -n "$_hits" && "$_hits" != *$'\n' ]] && _hits+=$'\n'
    done

    if [[ -t 1 ]] && check_cmd less; then
        grep -iE --color=always "${NOTES_PATTERN}|\$" "$_file" | less -R
    else
        cat "$_file"
    fi

    if [[ -n "$_hits" ]]; then
        say ""
        warn "Lines that may contain upgrade hints:"
        printf '%s' "$_hits" | grep -iE --color=auto "$NOTES_PATTERN" || true
    fi
}

# Versions whose notes are relevant when going from CURRENT to $1.
notes_range() {
    local _target="$1" _v
    for _v in "${VERSIONS[@]}"; do
        if ver_gt "$_target" "$CURRENT"; then
            # upgrade: (current, target]
            ver_gt "$_v" "$CURRENT" && ! ver_gt "$_v" "$_target" && printf '%s\n' "$_v"
        else
            # downgrade / reinstall: [target, current]
            ! ver_gt "$_target" "$_v" && ! ver_gt "$_v" "$CURRENT" && printf '%s\n' "$_v"
        fi
    done
    return 0
}

# --------------------------------------------------------------------------
# install
# --------------------------------------------------------------------------

download_and_verify() {
    local _ver="$1" _tag="${TAG_OF[$1]}" _dir="${TMP_DIR}/dl-$1" _bin_name _new_ver

    check_free_space "$TMP_DIR" 400
    check_free_space "$(dirname "$BIN")" 200
    mkdir -p "$_dir"
    info "⏳ Downloading ${ASSET} (${_tag})..."
    curl --proto '=https' --tlsv1.2 -fL --retry 3 --progress-bar \
        -o "${_dir}/${ASSET}" "${DOWNLOAD_URL}/${_tag}/${ASSET}" \
        || err "Download failed."

    if ! $VERIFY; then
        warn "Signature check skipped (--no-verify)."
    elif ! check_cmd cosign; then
        warn "cosign not installed -- skipping signature check."
    else
        info "🔏 Verifying signature with cosign..."
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
            -o "${_dir}/${ASSET}.sigstore.json" "${DOWNLOAD_URL}/${_tag}/${ASSET}.sigstore.json" \
            || err "Could not download ${ASSET}.sigstore.json (use --no-verify to skip)."
        cosign verify-blob \
            --bundle "${_dir}/${ASSET}.sigstore.json" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
            --certificate-identity-regexp "^https://github.com/${REPO}/" \
            "${_dir}/${ASSET}" \
            || err "Signature verification FAILED -- aborting."
        ok "Signature valid."
    fi

    tar -xzf "${_dir}/${ASSET}" -C "$_dir" || err "Could not extract ${ASSET}."
    _bin_name="$COMPONENT"
    [[ -f "${_dir}/${_bin_name}" ]] || _bin_name="stalwart"
    [[ -f "${_dir}/${_bin_name}" ]] || err "Binary not found in ${ASSET}."
    chmod 0755 "${_dir}/${_bin_name}"

    _new_ver="$(binary_version "${_dir}/${_bin_name}")"
    if [[ "$_new_ver" == "$_ver" ]]; then
        ok "Downloaded binary reports version ${_new_ver}."
    else
        warn "Downloaded binary reports version '${_new_ver:-?}', expected ${_ver}."
        confirm "Continue anyway?" || err "Aborted."
    fi

    # stage next to the target so the final mv is atomic
    STAGED_FILE="$(dirname "$BIN")/.stalwart.new.$$"
    # numeric ids: the root group is "wheel" on macOS / FreeBSD
    install -m 0755 -o 0 -g 0 "${_dir}/${_bin_name}" "$STAGED_FILE"
    rm -rf "$_dir"
}

# Aborts if the given directory has less than $2 MB free.
check_free_space() {
    local _avail_kb
    _avail_kb="$(df -Pk "$1" | awk 'NR == 2 { print $4 }')"
    if [[ -n "$_avail_kb" ]] && (( _avail_kb < $2 * 1024 )); then
        err "Only $(( _avail_kb / 1024 )) MB free in $1 -- need at least $2 MB (set TMPDIR to use another directory)."
    fi
}

install_version() {
    local _ver="$1" _new_ver _since _since_utc _i

    download_and_verify "$_ver"

    if $DRY_RUN; then
        warn "Dry run: would stop '${SERVICE}' (${SVC_TYPE}), replace ${BIN} with ${_ver} and start it again."
        rm -f "$STAGED_FILE"; STAGED_FILE=""
        return 0
    fi

    _since="$(date '+%Y-%m-%d %H:%M:%S')"
    _since_utc="$(date -u '+%Y-%m-%dT%H:%M:%S')"
    info "⏹  Stopping ${SERVICE} (${SVC_TYPE})..."
    svc_stop || warn "Stopping ${SERVICE} reported an error -- continuing."
    for (( _i = 0; _i < 30; _i++ )); do
        svc_is_active || break
        sleep 1
    done
    svc_is_active && warn "${SERVICE} still appears to be running."

    if ! mv -f "$STAGED_FILE" "$BIN"; then
        svc_start || true
        err "Could not replace ${BIN} -- old binary left in place, service restarted."
    fi
    STAGED_FILE=""
    info "▶️  Starting ${SERVICE}..."
    svc_start || warn "Starting ${SERVICE} reported an error."

    sleep 3
    _new_ver="$(binary_version "$BIN")"

    say ""
    svc_show_logs "$_since" "$_since_utc"
    say ""
    if svc_is_active; then
        ok "${SERVICE} is running, binary version ${_new_ver:-?}."
    else
        warn "${SERVICE} is NOT running after the update!"
        warn "Check the logs above. To roll back, run this script again"
        warn "and choose 'Downgrade' to ${CURRENT}."
    fi
    CURRENT="${_new_ver:-$_ver}"
}

# Shows notes, asks for confirmation and installs.
perform() {
    local _target="$1" _kind
    local -a _range

    if ver_gt "$_target" "$CURRENT"; then _kind="Upgrade"
    elif ver_gt "$CURRENT" "$_target"; then _kind="Downgrade"
    else _kind="Reinstall"; fi

    mapfile -t _range < <(notes_range "$_target")
    show_release_notes "${_range[@]}"

    say ""
    info "${_kind}: ${CURRENT} → ${_target}  (${ASSET})"
    if [[ "$_kind" == Downgrade ]]; then
        warn "Downgrades are not officially supported: newer versions may have migrated"
        warn "the data store or configuration, which older versions may not understand."
        warn "Make sure you can restore your data (restic) before continuing."
    fi
    if (( ${#_range[@]} > 1 )); then
        warn "This skips over ${#_range[@]} releases -- check ALL release notes above."
    fi

    confirm "Proceed with the ${_kind,,} to ${_target}?" || { say "Aborted."; return 0; }
    install_version "$_target"
}

main_menu() {
    local _answer _latest
    local -a _newer _older

    while true; do
        mapfile -t _newer < <(versions_newer | sort -Vr)
        mapfile -t _older < <(versions_older | sort -Vr)
        _latest="${VERSIONS[-1]}"

        say ""
        info "================ Stalwart upgrade ================"
        say "  Binary      : ${BIN}"
        say "  Architecture: ${ARCH}"
        say "  Component   : ${COMPONENT}"
        say "  Installed   : ${C_BOLD}${CURRENT}${C_RESET}"
        say "  Latest      : ${_latest}"
        $DRY_RUN && say "  Mode        : ${C_YELLOW}DRY RUN${C_RESET}"
        say ""
        if (( ${#_newer[@]} > 0 )); then
            say "  1) Upgrade    (${#_newer[@]} newer version(s) available)"
        else
            say "  1) Upgrade    (up to date)"
        fi
        say "  2) Downgrade  (${#_older[@]} older version(s))"
        say "  3) Reinstall current version"
        say "  4) Show release notes of a version"
        say "  q) Quit"
        read -r -p "Select: " _answer || exit 0

        case "$_answer" in
            1)
                if (( ${#_newer[@]} == 0 )); then ok "Already on the latest version."; continue; fi
                choose_version "Upgrade to:" 0 "${_newer[@]}"
                [[ -n "$CHOSEN" ]] && perform "$CHOSEN"
                ;;
            2)
                if (( ${#_older[@]} == 0 )); then warn "No older versions available."; continue; fi
                choose_version "Downgrade to:" "$DOWNGRADE_LIST_LIMIT" "${_older[@]}"
                [[ -n "$CHOSEN" ]] && perform "$CHOSEN"
                ;;
            3)
                if [[ -z "${TAG_OF[$CURRENT]:-}" ]]; then warn "Version ${CURRENT} not found on GitHub."; continue; fi
                perform "$CURRENT"
                ;;
            4)
                local -a _all
                mapfile -t _all < <(printf '%s\n' "${VERSIONS[@]}" | sort -Vr)
                choose_version "Show release notes of:" "$DOWNGRADE_LIST_LIMIT" "${_all[@]}"
                [[ -n "$CHOSEN" ]] && show_release_notes "$CHOSEN"
                ;;
            q | Q) exit 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

# --------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fdb) COMPONENT="stalwart-foundationdb" ;;
            --service) shift; SERVICE="${1:?--service needs a name}" ;;
            --include-prerelease) INCLUDE_PRERELEASE=true ;;
            --no-verify) VERIFY=false ;;
            --dry-run) DRY_RUN=true ;;
            -h | --help) print_usage; exit 0 ;;
            *) err "Unknown argument: $1 (try --help)" ;;
        esac
        shift
    done

    [[ "$(id -u)" -eq 0 ]] || err "This script needs to run as root."
    detect_os
    need_cmd curl jq tar uname mktemp install readlink sort grep sed df awk tail
    detect_service
    case "$SVC_TYPE" in
        systemd)     need_cmd systemctl journalctl ;;
        initd | rcd) need_cmd service ;;
        launchd)     need_cmd launchctl plutil ;;
    esac

    # /var/tmp is disk-backed; /tmp is often a small tmpfs
    TMP_DIR="$(mktemp -d "${TMPDIR:-/var/tmp}/stalwart-upgrade.XXXXXX")"
    trap cleanup EXIT

    info "🔍 Detecting installation..."
    detect_arch
    say "  OS / arch       : ${OS} / ${ARCH}"
    detect_binary_path
    detect_current_version
    detect_component
    say "  Installed       : ${CURRENT} (${COMPONENT})"

    info "🌐 Fetching releases from GitHub..."
    fetch_releases
    ok "${#VERSIONS[@]} releases provide ${ASSET}."

    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
