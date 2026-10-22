#!/usr/bin/env bash
#
# stalwart-upgrade.sh -- interactive upgrade / downgrade of a Stalwart binary
# that was installed with the official install.sh (Linux + systemd).
#
# - detects architecture, binary path (systemd unit vs. `which`) and version
# - lists newer / older releases from GitHub and lets you pick one
# - shows the release notes of every version in between before installing
# - optionally verifies the download with cosign (sigstore bundle)
# - does NOT keep a backup of the old binary (use your backups / GitHub)
#

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

Interactive upgrade / downgrade of Stalwart (Linux + systemd).

Options:
  --fdb                 Use the FoundationDB build (auto-detected otherwise).
  --service NAME        systemd unit name (default: stalwart).
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

detect_arch() {
    local _cpu _libc="gnu" _suffix="" _ldd _features

    [[ "$(uname -s)" == Linux ]] || err "Only Linux is supported."
    _cpu="$(uname -m)"

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

# Prints the binary path from the ExecStart= of the systemd unit
# (including drop-ins; the last non-empty ExecStart= wins).
service_exec_path() {
    local _line _path=""
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*ExecStart=(.*)$ ]] || continue
        _line="${BASH_REMATCH[1]}"
        [[ -z "$_line" ]] && continue
        _line="${_line#"${_line%%[![:space:]]*}"}"
        # strip systemd exec prefixes (-, @, +, !, :)
        while [[ "$_line" == [-@+!:]* ]]; do _line="${_line:1}"; done
        _path="${_line%% *}"
    done < <(systemctl cat "$SERVICE" 2>/dev/null)
    printf '%s' "$_path"
}

detect_binary_path() {
    local _unit_file _svc_path _which_path _svc_real _which_real

    systemctl cat "$SERVICE" > /dev/null 2>&1 \
        || err "systemd unit '${SERVICE}' not found (use --service NAME)."

    _unit_file="$(systemctl show -p FragmentPath --value "$SERVICE" 2>/dev/null || true)"
    _svc_path="$(service_exec_path)"
    [[ -n "$_svc_path" ]] || err "Could not read ExecStart= from unit '${SERVICE}'."

    if check_cmd which; then
        _which_path="$(which stalwart 2>/dev/null || true)"
    else
        _which_path="$(command -v stalwart 2>/dev/null || true)"
    fi

    say "  Service file    : ${_unit_file:-?}"
    say "  ExecStart binary: ${_svc_path}"
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
        _libs="$(ldd "$BIN" 2>&1 || true)"
        [[ "$_libs" == *libfdb_c* ]] && COMPONENT="stalwart-foundationdb"
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
    install -m 0755 -o root -g root "${_dir}/${_bin_name}" "$STAGED_FILE"
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
    local _ver="$1" _active _new_ver _since

    download_and_verify "$_ver"

    if $DRY_RUN; then
        warn "Dry run: would stop '${SERVICE}', replace ${BIN} with ${_ver} and start it again."
        rm -f "$STAGED_FILE"; STAGED_FILE=""
        return 0
    fi

    _since="$(date '+%Y-%m-%d %H:%M:%S')"
    info "⏹  Stopping ${SERVICE}..."
    systemctl stop "$SERVICE"
    if ! mv -f "$STAGED_FILE" "$BIN"; then
        systemctl start "$SERVICE" || true
        err "Could not replace ${BIN} -- old binary left in place, service restarted."
    fi
    STAGED_FILE=""
    info "▶️  Starting ${SERVICE}..."
    systemctl start "$SERVICE" || true

    sleep 3
    _active="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    _new_ver="$(binary_version "$BIN")"

    say ""
    journalctl -u "$SERVICE" --since "$_since" -n 50 --no-pager 2>/dev/null || true
    say ""
    if [[ "$_active" == active ]]; then
        ok "${SERVICE} is active, binary version ${_new_ver:-?}."
        CURRENT="${_new_ver:-$_ver}"
    else
        warn "${SERVICE} is '${_active}' after the update!"
        warn "Check: journalctl -u ${SERVICE} -e"
        warn "To roll back, run this script again and choose 'Downgrade' to ${CURRENT}."
        CURRENT="${_new_ver:-$_ver}"
    fi
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
    need_cmd curl jq tar systemctl journalctl uname mktemp install readlink sort grep sed df awk

    # /var/tmp is disk-backed; /tmp is often a small tmpfs
    TMP_DIR="$(mktemp -d -p "${TMPDIR:-/var/tmp}" stalwart-upgrade.XXXXXX)"
    trap cleanup EXIT

    info "🔍 Detecting installation..."
    detect_arch
    say "  Architecture    : ${ARCH}"
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
