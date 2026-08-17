#!/usr/bin/env bash
# BUILD_ID=20260817-1921-cachebust
set -uo pipefail

#  Surge Snell manager with:
# - Snell v5 + ShadowTLS v3 wrapping
# - systemd + Alpine/OpenRC support
# - persistent `snell` management shortcut

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

print_header()  { echo; echo -e "${BOLD}${BLUE}===========================================================${NC}"; echo -e "${BOLD}${BLUE}  $1${NC}"; echo -e "${BOLD}${BLUE}===========================================================${NC}"; echo; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }

INSTALL_BIN="/usr/local/bin/snell-server"
CONFIG_DIR="/etc/snell"
CONFIG_FILE="$CONFIG_DIR/snell-server.conf"
META_FILE="$CONFIG_DIR/.install_meta"
SERVICE_NAME="snell-server"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

SHADOWTLS_BIN="/usr/local/bin/shadow-tls"
SHADOWTLS_SERVICE_NAME="shadow-tls"
SHADOWTLS_SYSTEMD_FILE="/etc/systemd/system/${SHADOWTLS_SERVICE_NAME}.service"
SHADOWTLS_OPENRC_FILE="/etc/init.d/${SHADOWTLS_SERVICE_NAME}"
SHADOWTLS_REPO="ihciah/shadow-tls"

MANAGER_BIN="/usr/local/libexec/snell-manager"
SHORTCUT_BIN="/usr/local/bin/snell"

# GitHub deployment source for this manager itself.
# Before publishing, set SNELL_MANAGER_GITHUB_REPO_DEFAULT to your own repo,
# e.g. "yourname/opensnell-manager". Users can also override it at runtime.
SNELL_MANAGER_GITHUB_REPO_DEFAULT="CINGDAAT/snell-manager"
SNELL_MANAGER_GITHUB_BRANCH_DEFAULT="main"
SNELL_MANAGER_GITHUB_PATH_DEFAULT="snell-manager-shadowtls-alpine.sh"
SNELL_MANAGER_GITHUB_REPO="${SNELL_MANAGER_GITHUB_REPO:-$SNELL_MANAGER_GITHUB_REPO_DEFAULT}"
SNELL_MANAGER_GITHUB_BRANCH="${SNELL_MANAGER_GITHUB_BRANCH:-$SNELL_MANAGER_GITHUB_BRANCH_DEFAULT}"
SNELL_MANAGER_GITHUB_PATH="${SNELL_MANAGER_GITHUB_PATH:-$SNELL_MANAGER_GITHUB_PATH_DEFAULT}"
SNELL_MANAGER_RAW_URL="${SNELL_MANAGER_RAW_URL:-}"

OPENSNELL_REPO="missuo/opensnell"
OPENSNELL_RELEASE_API="https://api.github.com/repos/${OPENSNELL_REPO}/releases/latest"
SURGE_V5_VERSION="v5.0.1"
SURGE_V6_VERSION="v6.0.0rc2"
SURGE_BASE_URL="https://dl.nssurge.com/snell"

OS_ID=""
INIT_SYSTEM=""

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root."
        exit 1
    fi
}

check_linux() {
    if [ "$(uname -s)" != "Linux" ]; then
        print_error "This installer is Linux-only."
        exit 1
    fi
}

detect_os() {
    OS_ID="unknown"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    fi
}

detect_init() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        print_error "Neither systemd nor OpenRC was detected."
        print_info "Supported init systems: systemd, Alpine OpenRC."
        exit 1
    fi
}

ensure_tools() {
    local missing=() t
    for t in curl unzip openssl ss; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done

    if [ "$OS_ID" = "alpine" ]; then
        # Alpine uses musl. Official Surge Snell binaries are glibc-linked;
        # gcompat provides the compatibility loader/APIs for many such binaries.
        local apk_pkgs=(ca-certificates curl unzip openssl iproute2 gcompat)
        print_info "Ensuring Alpine dependencies: ${apk_pkgs[*]}"
        apk add --no-cache "${apk_pkgs[@]}" >/dev/null || {
            print_error "Failed to install Alpine dependencies."; exit 1; }
        update-ca-certificates >/dev/null 2>&1 || true
        return 0
    fi

    [ "${#missing[@]}" -eq 0 ] && return 0
    print_info "Installing missing tools: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing[@]}"
    else
        print_error "Unsupported package manager. Install manually: ${missing[*]}"
        exit 1
    fi
}

detect_arch_opensnell() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        i386|i686) echo "386" ;;
        armv7l|armv7) echo "armv7" ;;
        *) print_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
}

detect_arch_surge() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        i386|i686) echo "i386" ;;
        armv7l|armv7) echo "armv7l" ;;
        *) print_error "Surge binary unavailable for $(uname -m)"; exit 1 ;;
    esac
}

detect_arch_shadowtls() {
    case "$(uname -m)" in
        x86_64) echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        armv7l|armv7) echo "armv7-unknown-linux-musleabihf" ;;
        armv6l|arm) echo "arm-unknown-linux-musleabi" ;;
        i386|i686)
            print_error "Upstream ShadowTLS does not publish a 32-bit x86 Linux binary."
            return 1
            ;;
        *) print_error "ShadowTLS binary unavailable for $(uname -m)"; return 1 ;;
    esac
}

gen_psk() { openssl rand -base64 48 | tr -d '/+=' | cut -c1-32; }
gen_safe_secret() { openssl rand -hex 24; }

prompt_default() {
    local question="$1" default="$2" reply
    if [ -n "$default" ]; then
        read -r -p "$(echo -e "${CYAN}${question} [${BOLD}${default}${NC}${CYAN}]: ${NC}")" reply
    else
        read -r -p "$(echo -e "${CYAN}${question}: ${NC}")" reply
    fi
    echo "${reply:-$default}"
}

prompt_yesno() {
    local question="$1" default="$2" reply
    read -r -p "$(echo -e "${CYAN}${question} (y/n) [${BOLD}${default}${NC}${CYAN}]: ${NC}")" reply
    reply="${reply:-$default}"
    case "${reply,,}" in y|yes) echo y ;; *) echo n ;; esac
}

pick_free_port() {
    local p
    for _ in $(seq 1 80); do
        p=$(( RANDOM % 50000 + 10000 ))
        if ! ss -lnt -lnu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$"; then
            echo "$p"; return 0
        fi
    done
    print_error "Could not find a free port"
    return 1
}

get_ipv4() {
    curl -s -4 --max-time 5 https://ip.sb 2>/dev/null \
        || curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "YOUR_SERVER_IP"
}

meta_get() {
    local key="$1"
    [ -f "$META_FILE" ] || return 0
    grep -E "^${key}=" "$META_FILE" | tail -1 | cut -d= -f2- || true
}

meta_set_many() {
    mkdir -p "$CONFIG_DIR"
    local tmp="${META_FILE}.new" key line
    touch "$META_FILE"
    cp "$META_FILE" "$tmp"
    for line in "$@"; do
        key="${line%%=*}"
        grep -vE "^${key}=" "$tmp" > "${tmp}.2" || true
        mv "${tmp}.2" "$tmp"
        printf '%s\n' "$line" >> "$tmp"
    done
    mv "$tmp" "$META_FILE"
    chmod 600 "$META_FILE"
}

manager_raw_url() {
    local saved=""
    [ -f "$META_FILE" ] && saved=$(meta_get manager_raw_url)
    if [ -n "$SNELL_MANAGER_RAW_URL" ]; then
        printf '%s\n' "$SNELL_MANAGER_RAW_URL"
    elif [ -n "$saved" ]; then
        printf '%s\n' "$saved"
    elif [ -n "$SNELL_MANAGER_GITHUB_REPO" ]; then
        printf 'https://raw.githubusercontent.com/%s/%s/%s\n' \
            "$SNELL_MANAGER_GITHUB_REPO" "$SNELL_MANAGER_GITHUB_BRANCH" "$SNELL_MANAGER_GITHUB_PATH"
    fi
}

validate_github_raw_url() {
    local url="$1"
    case "$url" in
        https://raw.githubusercontent.com/*|https://github.com/*/raw/*) return 0 ;;
        *) return 1 ;;
    esac
}

remember_manager_source() {
    local url
    url=$(manager_raw_url)
    [ -n "$url" ] || return 0
    if validate_github_raw_url "$url"; then
        meta_set_many "manager_raw_url=$url"
    fi
}

install_shortcut() {
    mkdir -p "$(dirname "$MANAGER_BIN")"
    local src="${BASH_SOURCE[0]}"
    local src_real="" dst_real="" url="" tmp=""
    src_real=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
    dst_real=$(readlink -f "$MANAGER_BIN" 2>/dev/null || printf '%s' "$MANAGER_BIN")

    if [ "$src_real" != "$dst_real" ] && [ -r "$src" ] && [ -f "$src" ]; then
        cp "$src" "$MANAGER_BIN"
        chmod 0755 "$MANAGER_BIN"
    elif [ ! -x "$MANAGER_BIN" ]; then
        # `curl ... | bash` has no regular source file to copy. Fetch the
        # manager again from its configured GitHub Raw URL so the `snell`
        # command remains available after this process exits.
        url=$(manager_raw_url)
        if [ -n "$url" ] && validate_github_raw_url "$url"; then
            tmp=$(mktemp)
            if curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp" "$url" && bash -n "$tmp"; then
                install -m 0755 "$tmp" "$MANAGER_BIN"
            else
                rm -f "$tmp"
                print_error "Could not persist the manager from GitHub: $url"
                return 1
            fi
            rm -f "$tmp"
        else
            print_error "Cannot persist the 'snell' shortcut when running from stdin."
            print_info "Publish with SNELL_MANAGER_GITHUB_REPO_DEFAULT set, or use bash <(curl -fsSL RAW_URL)."
            return 1
        fi
    fi

    ln -sfn "$MANAGER_BIN" "$SHORTCUT_BIN"
    remember_manager_source
    print_success "Management shortcut installed: run 'snell' anytime"
}

enable_tfo_sysctl() {
    local current
    current=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "")
    if [ "$current" = "3" ]; then
        print_info "TCP Fast Open already enabled (net.ipv4.tcp_fastopen=3)"
        return 0
    fi
    local confirm
    confirm=$(prompt_yesno "Set net.ipv4.tcp_fastopen=3 persistently" "y")
    [ "$confirm" = "y" ] || return 0
    mkdir -p /etc/sysctl.d
    printf '%s\n' 'net.ipv4.tcp_fastopen = 3' > /etc/sysctl.d/99-snell-tfo.conf
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
    print_success "TCP Fast Open enabled"
}

download_opensnell() {
    print_header "Downloading OpenSnell"
    mkdir -p "$CONFIG_DIR"
    local arch tag url tmp
    arch=$(detect_arch_opensnell)
    tag=$(curl -fsSL "$OPENSNELL_RELEASE_API" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    [ -n "$tag" ] || { print_error "Could not resolve latest OpenSnell release"; exit 1; }
    url="https://github.com/${OPENSNELL_REPO}/releases/download/${tag}/snell-server-linux-${arch}"
    tmp=$(mktemp)
    curl -fL --progress-bar -o "$tmp" "$url" || { rm -f "$tmp"; print_error "Download failed"; exit 1; }
    install -m 0755 "$tmp" "$INSTALL_BIN"
    rm -f "$tmp"
    printf 'variant=opensnell\nversion=%s\nproto=5\n' "$tag" > "$META_FILE.tmp"
    print_success "Installed OpenSnell $tag"
}

download_surge() {
    local version="$1" proto=5 arch url workdir
    case "$version" in v6*) proto=6 ;; esac
    print_header "Downloading Surge official snell-server"
    mkdir -p "$CONFIG_DIR"
    arch=$(detect_arch_surge)
    if [ "$proto" = 6 ] && [ "$arch" = armv7l ]; then
        print_error "Surge Snell v6 is not available for armv7l"
        exit 1
    fi
    url="${SURGE_BASE_URL}/snell-server-${version}-linux-${arch}.zip"
    workdir=$(mktemp -d)
    curl -fL --progress-bar -o "$workdir/snell.zip" "$url" || { rm -rf "$workdir"; print_error "Download failed"; exit 1; }
    unzip -q "$workdir/snell.zip" -d "$workdir"
    install -m 0755 "$workdir/snell-server" "$INSTALL_BIN"
    rm -rf "$workdir"

    if ! "$INSTALL_BIN" -v >/dev/null 2>&1; then
        if [ "$OS_ID" = alpine ]; then
            print_error "Official Snell ${version} still cannot run on Alpine after installing gcompat."
            print_info "Use OpenSnell on this host, or run official Snell in a glibc-based container/chroot."
        else
            print_error "snell-server ${version} failed its runtime check."
        fi
        exit 1
    fi
    printf 'variant=surge\nversion=%s\nproto=%s\n' "$version" "$proto" > "$META_FILE.tmp"
    print_success "Installed Surge snell-server ${version}"
}

download_shadowtls() {
    local target url tmp
    target=$(detect_arch_shadowtls) || return 1
    url="https://github.com/${SHADOWTLS_REPO}/releases/latest/download/shadow-tls-${target}"
    print_header "Downloading ShadowTLS"
    print_info "Asset: shadow-tls-${target}"
    tmp=$(mktemp)
    curl -fL --progress-bar -o "$tmp" "$url" || { rm -f "$tmp"; print_error "ShadowTLS download failed"; return 1; }
    install -m 0755 "$tmp" "$SHADOWTLS_BIN"
    rm -f "$tmp"
    if ! "$SHADOWTLS_BIN" --version >/dev/null 2>&1; then
        print_error "ShadowTLS binary failed its runtime check"
        return 1
    fi
    print_success "ShadowTLS installed"
}

build_config() {
    local variant proto
    if [ -f "$META_FILE.tmp" ]; then
        variant=$(grep '^variant=' "$META_FILE.tmp" | cut -d= -f2)
        proto=$(grep '^proto=' "$META_FILE.tmp" | cut -d= -f2)
    else
        variant=$(meta_get variant); proto=$(meta_get proto)
    fi
    variant="${variant:-opensnell}"; proto="${proto:-5}"

    print_header "Snell server configuration"
    mkdir -p "$CONFIG_DIR"

    local public_port psk mode=default obfs=off ipv6=true dns_pref=default dns_servers="" egress=""
    local udp=true quic=true tfo=false shadowtls=false shadowtls_sni="" shadowtls_password="" snell_port=""

    public_port=$(prompt_default "Public listen port" "$(meta_get port)")
    [ -n "$public_port" ] || public_port=$(pick_free_port)
    if ! [[ "$public_port" =~ ^[0-9]+$ ]] || [ "$public_port" -lt 1 ] || [ "$public_port" -gt 65535 ]; then
        print_error "Invalid port: $public_port"; exit 1
    fi

    psk=$(prompt_default "Snell PSK (blank = generate)" "$(meta_get psk)")
    if [ -z "$psk" ]; then psk=$(gen_psk); print_info "Generated Snell PSK: $psk"; fi

    if [ "$proto" = 6 ]; then
        local psk_len
        psk_len=$(printf '%s' "$psk" | wc -c | tr -d ' ')
        if [ "$psk_len" -lt 16 ] || [ "$psk_len" -gt 255 ]; then
            print_error "Snell v6 PSK must be 16..255 bytes"; exit 1
        fi
        mode=$(prompt_default "Traffic mode (default/unshaped/unsafe-raw)" "$(meta_get mode)")
        mode="${mode:-default}"
        case "$mode" in default|unshaped|unsafe-raw) ;; *) print_error "Invalid mode"; exit 1 ;; esac
        dns_pref=$(prompt_default "DNS IP preference" "$(meta_get dns_pref)")
        dns_pref="${dns_pref:-default}"
        case "$dns_pref" in default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) ;; *) print_error "Invalid DNS preference"; exit 1 ;; esac
        dns_servers=$(prompt_default "Custom DNS servers (comma-separated, optional)" "")
        egress=$(prompt_default "Egress interface (optional)" "")
    else
        local ipv6_choice
        obfs=$(prompt_default "Snell v5 built-in obfs (off/http)" "$(meta_get obfs)")
        obfs="${obfs:-off}"
        case "$obfs" in off|http) ;; *) print_error "Snell v5 obfs must be off or http"; exit 1 ;; esac
        ipv6_choice=$(prompt_yesno "Allow IPv6 destinations" "y")
        [ "$ipv6_choice" = n ] && ipv6=false
    fi

    if [ "$proto" = 5 ]; then
        local stls_choice stls_default="n"
        [ "$(meta_get shadowtls)" = true ] && stls_default="y"
        stls_choice=$(prompt_yesno "Wrap Snell v5 with ShadowTLS v3" "$stls_default")
        if [ "$stls_choice" = y ]; then
            shadowtls=true
            obfs=off
            snell_port=$(pick_free_port)
            if [ "$snell_port" = "$public_port" ]; then snell_port=$(pick_free_port); fi
            shadowtls_sni=$(prompt_default "ShadowTLS SNI / handshake host" "$(meta_get shadowtls_sni)")
            shadowtls_sni="${shadowtls_sni:-www.microsoft.com}"
            if ! [[ "$shadowtls_sni" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
                print_error "Invalid SNI hostname: $shadowtls_sni"; exit 1
            fi
            shadowtls_password=$(prompt_default "ShadowTLS password (blank = generate)" "$(meta_get shadowtls_password)")
            if [ -z "$shadowtls_password" ]; then shadowtls_password=$(gen_safe_secret); print_info "Generated ShadowTLS password: $shadowtls_password"; fi
            if ! [[ "$shadowtls_password" =~ ^[A-Za-z0-9._~-]+$ ]]; then
                print_error "ShadowTLS password may contain only A-Z a-z 0-9 . _ ~ -"; exit 1
            fi
            download_shadowtls || exit 1
            print_warning "ShadowTLS is TCP-only. Snell v5 QUIC Proxy Mode's direct UDP side channel is not exposed."
        fi
    fi

    if [ "$variant" = opensnell ]; then
        local udp_choice quic_choice tfo_choice
        udp_choice=$(prompt_yesno "Accept UDP-over-TCP" "y"); [ "$udp_choice" = n ] && udp=false
        if [ "$shadowtls" = true ]; then
            quic=false
        else
            quic_choice=$(prompt_yesno "Enable OpenSnell QUIC proxy mode" "y"); [ "$quic_choice" = n ] && quic=false
        fi
        egress=$(prompt_default "Egress interface (optional)" "$egress")
        tfo_choice=$(prompt_yesno "Enable TCP Fast Open" "n"); [ "$tfo_choice" = y ] && tfo=true
    else
        local tfo_choice
        tfo_choice=$(prompt_yesno "Enable TCP Fast Open" "y"); [ "$tfo_choice" = y ] && tfo=true
    fi

    local listen_addr="0.0.0.0:${public_port}"
    if [ "$shadowtls" = true ]; then listen_addr="127.0.0.1:${snell_port}"; fi

    if [ "$proto" = 6 ]; then
        cat > "$CONFIG_FILE" <<CFG
[snell-server]
listen = ${listen_addr}
psk = ${psk}
mode = ${mode}
dns-ip-preference = ${dns_pref}
CFG
        [ -n "$dns_servers" ] && echo "dns = ${dns_servers}" >> "$CONFIG_FILE"
        [ -n "$egress" ] && echo "egress-interface = ${egress}" >> "$CONFIG_FILE"
    else
        cat > "$CONFIG_FILE" <<CFG
[snell-server]
listen = ${listen_addr}
psk = ${psk}
obfs = ${obfs}
ipv6 = ${ipv6}
CFG
        if [ "$variant" = opensnell ]; then
            cat >> "$CONFIG_FILE" <<CFG
udp = ${udp}
quic = ${quic}
egress-interface = ${egress}
tfo = ${tfo}
CFG
        fi
    fi
    chmod 600 "$CONFIG_FILE"

    [ "$tfo" = true ] && enable_tfo_sysctl

    if [ -f "$META_FILE.tmp" ]; then mv "$META_FILE.tmp" "$META_FILE"; fi
    meta_set_many \
        "port=$public_port" "snell_port=${snell_port:-$public_port}" "psk=$psk" \
        "obfs=$obfs" "ipv6=$ipv6" "tfo=$tfo" "mode=$mode" "dns_pref=$dns_pref" \
        "shadowtls=$shadowtls" "shadowtls_version=3" "shadowtls_sni=$shadowtls_sni" \
        "shadowtls_password=$shadowtls_password"
    print_success "Configuration written to $CONFIG_FILE"
}

write_snell_service() {
    if [ "$INIT_SYSTEM" = systemd ]; then
        cat > "$SYSTEMD_SERVICE_FILE" <<UNIT
[Unit]
Description=Snell server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
    else
        cat > "$OPENRC_SERVICE_FILE" <<'RC'
#!/sbin/openrc-run
name="Snell server"
description="Snell proxy server"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell/snell-server.conf"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/snell-server.log"
error_log="/var/log/snell-server.err"
depend() { need net; }
RC
        chmod 0755 "$OPENRC_SERVICE_FILE"
    fi
    print_success "Snell service installed for $INIT_SYSTEM"
}

write_shadowtls_service() {
    local enabled sni password public_port snell_port tfo fastopen=""
    enabled=$(meta_get shadowtls)
    if [ "$enabled" != true ]; then
        remove_shadowtls_service_only
        return 0
    fi
    sni=$(meta_get shadowtls_sni); password=$(meta_get shadowtls_password)
    public_port=$(meta_get port); snell_port=$(meta_get snell_port); tfo=$(meta_get tfo)
    [ "$tfo" = true ] && fastopen="--fastopen"

    if [ "$INIT_SYSTEM" = systemd ]; then
        cat > "$SHADOWTLS_SYSTEMD_FILE" <<UNIT
[Unit]
Description=ShadowTLS v3 wrapper for Snell
After=network.target ${SERVICE_NAME}.service
Requires=${SERVICE_NAME}.service

[Service]
Type=simple
Environment=RUST_LOG=error
ExecStart=${SHADOWTLS_BIN} ${fastopen} --v3 server --listen 0.0.0.0:${public_port} --server 127.0.0.1:${snell_port} --tls ${sni}:443 --password ${password}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
    else
        cat > "$SHADOWTLS_OPENRC_FILE" <<RC
#!/sbin/openrc-run
name="ShadowTLS"
description="ShadowTLS v3 wrapper for Snell"
command="${SHADOWTLS_BIN}"
command_args="${fastopen} --v3 server --listen 0.0.0.0:${public_port} --server 127.0.0.1:${snell_port} --tls ${sni}:443 --password ${password}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/shadow-tls.log"
error_log="/var/log/shadow-tls.err"
export RUST_LOG="error"
depend() { need net; after snell-server; }
RC
        chmod 0755 "$SHADOWTLS_OPENRC_FILE"
    fi
    print_success "ShadowTLS service installed for $INIT_SYSTEM"
}

remove_shadowtls_service_only() {
    if [ "$INIT_SYSTEM" = systemd ]; then
        systemctl stop "$SHADOWTLS_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SHADOWTLS_SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SHADOWTLS_SYSTEMD_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rc-service "$SHADOWTLS_SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SHADOWTLS_SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "$SHADOWTLS_OPENRC_FILE"
    fi
}

svc_start() {
    local svc="$1"
    if [ "$INIT_SYSTEM" = systemd ]; then systemctl start "$svc"; else rc-service "$svc" start; fi
}
svc_stop() {
    local svc="$1"
    if [ "$INIT_SYSTEM" = systemd ]; then systemctl stop "$svc"; else rc-service "$svc" stop; fi
}
svc_restart() {
    local svc="$1"
    if [ "$INIT_SYSTEM" = systemd ]; then systemctl restart "$svc"; else rc-service "$svc" restart; fi
}
svc_enable() {
    local svc="$1"
    if [ "$INIT_SYSTEM" = systemd ]; then systemctl enable "$svc" >/dev/null 2>&1; else rc-update add "$svc" default >/dev/null 2>&1; fi
}
svc_disable() {
    local svc="$1"
    if [ "$INIT_SYSTEM" = systemd ]; then systemctl disable "$svc" >/dev/null 2>&1; else rc-update del "$svc" default >/dev/null 2>&1; fi
}
svc_is_active() {
    local svc="$1"
    if [ "$INIT_SYSTEM" = systemd ]; then systemctl is-active --quiet "$svc"; else rc-service "$svc" status >/dev/null 2>&1; fi
}

start_stack() {
    svc_start "$SERVICE_NAME"
    [ "$(meta_get shadowtls)" = true ] && svc_start "$SHADOWTLS_SERVICE_NAME"
    print_success "Proxy stack started"
}
stop_stack() {
    [ "$(meta_get shadowtls)" = true ] && svc_stop "$SHADOWTLS_SERVICE_NAME" >/dev/null 2>&1 || true
    svc_stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    print_success "Proxy stack stopped"
}
restart_stack() {
    svc_restart "$SERVICE_NAME"
    if [ "$(meta_get shadowtls)" = true ]; then
        if svc_is_active "$SHADOWTLS_SERVICE_NAME"; then svc_restart "$SHADOWTLS_SERVICE_NAME"; else svc_start "$SHADOWTLS_SERVICE_NAME"; fi
    fi
    print_success "Proxy stack restarted"
}
enable_stack() {
    svc_enable "$SERVICE_NAME"
    [ "$(meta_get shadowtls)" = true ] && svc_enable "$SHADOWTLS_SERVICE_NAME"
    print_success "Auto-start enabled"
}
disable_stack() {
    [ "$(meta_get shadowtls)" = true ] && svc_disable "$SHADOWTLS_SERVICE_NAME" >/dev/null 2>&1 || true
    svc_disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    print_success "Auto-start disabled"
}

status_stack() {
    print_header "Service Status"
    if [ "$INIT_SYSTEM" = systemd ]; then
        systemctl status "$SERVICE_NAME" --no-pager 2>&1 | head -15 || true
        if [ "$(meta_get shadowtls)" = true ]; then
            echo
            systemctl status "$SHADOWTLS_SERVICE_NAME" --no-pager 2>&1 | head -15 || true
        fi
    else
        rc-service "$SERVICE_NAME" status || true
        [ "$(meta_get shadowtls)" = true ] && rc-service "$SHADOWTLS_SERVICE_NAME" status || true
    fi
}

configure_firewall() {
    local port
    port=$(meta_get port); [ -n "$port" ] || return 0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        print_success "UFW: TCP/${port} opened"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        print_success "firewalld: TCP/${port} opened"
    else
        print_info "No supported active firewall manager detected; ensure TCP/${port} is reachable."
    fi
}

show_info() {
    [ -f "$META_FILE" ] || { print_warning "No installation metadata found"; return 1; }
    local variant version proto port psk tfo ip stls sni stls_pass node
    variant=$(meta_get variant); version=$(meta_get version); proto=$(meta_get proto); proto="${proto:-5}"
    port=$(meta_get port); psk=$(meta_get psk); tfo=$(meta_get tfo)
    stls=$(meta_get shadowtls); sni=$(meta_get shadowtls_sni); stls_pass=$(meta_get shadowtls_password)
    ip=$(get_ipv4); [ -n "$ip" ] || ip="YOUR_SERVER_IP"
    node="Snell-${proto}"

    print_header "Connection Info"
    echo -e "${BOLD}Variant:${NC}      ${variant} (${version})"
    echo -e "${BOLD}Server:${NC}       ${ip}:${port}"
    echo -e "${BOLD}Snell:${NC}        v${proto}"
    echo -e "${BOLD}PSK:${NC}          ${psk}"
    if [ "$stls" = true ]; then
        echo -e "${BOLD}ShadowTLS:${NC}    v3"
        echo -e "${BOLD}SNI:${NC}          ${sni}"
        echo -e "${BOLD}STLS password:${NC} ${stls_pass}"
        echo -e "${BOLD}Inner Snell:${NC}  127.0.0.1:$(meta_get snell_port)"

        print_header "Surge [Proxy]"
        local tfo_arg=""
        [ "$tfo" = true ] && tfo_arg=", tfo=true"
        echo -e "${GREEN}${node}-STLS = snell, ${ip}, ${port}, psk=\"${psk}\", version=${proto}, reuse=true, shadow-tls-password=\"${stls_pass}\", shadow-tls-version=3, shadow-tls-sni=${sni}${tfo_arg}${NC}"

        if [ "$proto" = 5 ]; then
            print_header "Mihomo / Clash.Meta"
            cat <<YAML
- name: "${node}-STLS"
  type: snell
  server: "${ip}"
  port: ${port}
  psk: "${psk}"
  version: 5
  udp: true
  reuse: true
  client-fingerprint: chrome
  obfs-opts:
    mode: shadow-tls
    host: "${sni}"
    password: "${stls_pass}"
    version: 3
    alpn: ["h2", "http/1.1"]
YAML
        fi
    else
        print_header "Surge [Proxy]"
        echo -e "${GREEN}${node} = snell, ${ip}, ${port}, psk=\"${psk}\", version=${proto}${NC}"
    fi

    print_header "Runtime"
    if svc_is_active "$SERVICE_NAME"; then print_success "snell-server is running"; else print_warning "snell-server is not running"; fi
    if [ "$stls" = true ]; then
        if svc_is_active "$SHADOWTLS_SERVICE_NAME"; then print_success "shadow-tls is running"; else print_warning "shadow-tls is not running"; fi
    fi
}

do_install() {
    check_root; detect_os; ensure_tools; detect_init
    install_shortcut
    print_header "OpenSnell / Snell Installer"
    echo -e "${GREEN}1)${NC} OpenSnell (protocol v5 compatible)"
    echo -e "${GREEN}2)${NC} Surge official Snell ${SURGE_V5_VERSION}"
    echo -e "${GREEN}3)${NC} Surge official Snell ${SURGE_V6_VERSION}"
    local choice
    read -r -p "$(echo -e "${CYAN}Variant [${BOLD}1${NC}${CYAN}]: ${NC}")" choice
    case "${choice:-1}" in
        1) download_opensnell ;;
        2) download_surge "$SURGE_V5_VERSION" ;;
        3) download_surge "$SURGE_V6_VERSION" ;;
        *) print_error "Invalid choice"; exit 1 ;;
    esac
    build_config
    write_snell_service
    write_shadowtls_service
    configure_firewall
    enable_stack
    restart_stack
    show_info
}

do_reconfigure() {
    check_root; detect_os; ensure_tools; detect_init; install_shortcut
    [ -x "$INSTALL_BIN" ] || { print_error "Install Snell first"; exit 1; }
    build_config
    write_snell_service
    write_shadowtls_service
    configure_firewall
    enable_stack
    restart_stack
    show_info
}

do_update() {
    check_root; detect_os; ensure_tools; detect_init; install_shortcut
    local variant version
    variant=$(meta_get variant); version=$(meta_get version)
    if [ "$variant" = surge ]; then
        case "$version" in v6*) download_surge "$SURGE_V6_VERSION" ;; *) download_surge "$SURGE_V5_VERSION" ;; esac
    else
        download_opensnell
    fi
    if [ -f "$META_FILE.tmp" ]; then
        local new_variant new_version new_proto
        new_variant=$(grep '^variant=' "$META_FILE.tmp" | cut -d= -f2)
        new_version=$(grep '^version=' "$META_FILE.tmp" | cut -d= -f2)
        new_proto=$(grep '^proto=' "$META_FILE.tmp" | cut -d= -f2)
        rm -f "$META_FILE.tmp"
        meta_set_many "variant=$new_variant" "version=$new_version" "proto=$new_proto"
    fi
    if [ "$(meta_get shadowtls)" = true ]; then download_shadowtls || exit 1; fi
    restart_stack
    print_success "Update complete"
}

show_github_deploy() {
    local url repo branch path
    url=$(manager_raw_url)
    repo="$SNELL_MANAGER_GITHUB_REPO"
    branch="$SNELL_MANAGER_GITHUB_BRANCH"
    path="$SNELL_MANAGER_GITHUB_PATH"

    print_header "GitHub Quick Deploy"
    if [ -z "$url" ]; then
        print_warning "GitHub source is not configured yet."
        echo "Set one of these before publishing the script:"
        echo "  SNELL_MANAGER_GITHUB_REPO_DEFAULT=\"yourname/yourrepo\""
        echo "or run: snell github-config"
        return 1
    fi

    echo -e "${BOLD}Raw URL:${NC} $url"
    [ -n "$repo" ] && echo -e "${BOLD}Repository:${NC} ${repo} (${branch}:${path})"
    echo
    echo -e "${BOLD}Debian / Ubuntu / RHEL / existing Bash:${NC}"
    echo "  bash <(curl -fsSL '$url') install"
    echo
    echo -e "${BOLD}Pipe form:${NC}"
    echo "  curl -fsSL '$url' | bash -s -- install"
    echo
    echo -e "${BOLD}Alpine minimal image:${NC}"
    echo "  apk add --no-cache bash curl ca-certificates && bash <(curl -fsSL '$url') install"
    echo
    echo -e "${BOLD}Manager self-update:${NC}"
    echo "  snell self-update"
}

do_github_config() {
    check_root
    local current repo branch path url choice
    current=$(manager_raw_url)
    print_header "Configure GitHub Deployment Source"
    if [ -n "$current" ]; then
        print_info "Current source: $current"
    fi

    choice=$(prompt_default "Configure by repo (repo) or full raw URL (url)" "repo")
    case "$choice" in
        repo)
            repo=$(prompt_default "GitHub repository (owner/repo)" "$SNELL_MANAGER_GITHUB_REPO")
            if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
                print_error "Invalid GitHub repository. Expected owner/repo."
                return 1
            fi
            branch=$(prompt_default "Branch" "$SNELL_MANAGER_GITHUB_BRANCH")
            path=$(prompt_default "Script path in repository" "$SNELL_MANAGER_GITHUB_PATH")
            url="https://raw.githubusercontent.com/${repo}/${branch}/${path}"
            ;;
        url)
            url=$(prompt_default "Full GitHub raw URL" "$current")
            if ! validate_github_raw_url "$url"; then
                print_error "Only GitHub raw URLs are accepted."
                return 1
            fi
            ;;
        *)
            print_error "Choose repo or url"
            return 1
            ;;
    esac

    meta_set_many "manager_raw_url=$url"
    print_success "GitHub deployment source saved"
    show_github_deploy
}

do_manager_self_update() {
    check_root; detect_os; ensure_tools
    local url tmp backup
    url=$(manager_raw_url)
    if [ -z "$url" ]; then
        print_error "GitHub deployment source is not configured."
        print_info "Run: snell github-config"
        return 1
    fi
    if ! validate_github_raw_url "$url"; then
        print_error "Refusing non-GitHub manager source: $url"
        return 1
    fi

    print_header "Updating Snell Manager from GitHub"
    print_info "Source: $url"
    tmp=$(mktemp)
    backup="${MANAGER_BIN}.bak"
    if ! curl -fL --retry 3 --connect-timeout 10 -o "$tmp" "$url"; then
        rm -f "$tmp"
        print_error "Failed to download manager script"
        return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        print_error "Downloaded manager failed bash syntax validation"
        return 1
    fi
    if ! grep -q 'Snell + ShadowTLS Management Menu' "$tmp"; then
        rm -f "$tmp"
        print_error "Downloaded file does not look like this Snell manager"
        return 1
    fi

    [ -f "$MANAGER_BIN" ] && cp -f "$MANAGER_BIN" "$backup"
    install -m 0755 "$tmp" "$MANAGER_BIN"
    rm -f "$tmp"
    ln -sfn "$MANAGER_BIN" "$SHORTCUT_BIN"
    meta_set_many "manager_raw_url=$url"
    print_success "Manager updated from GitHub"
    [ -f "$backup" ] && print_info "Previous manager backup: $backup"
}

do_uninstall() {
    check_root; detect_os; detect_init
    local confirm rm_cfg
    print_warning "This removes Snell, ShadowTLS services/binaries, and the 'snell' shortcut."
    confirm=$(prompt_yesno "Continue" "n")
    [ "$confirm" = y ] || { print_info "Aborted"; return; }
    stop_stack >/dev/null 2>&1 || true
    disable_stack >/dev/null 2>&1 || true
    remove_shadowtls_service_only
    if [ "$INIT_SYSTEM" = systemd ]; then
        rm -f "$SYSTEMD_SERVICE_FILE"; systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f "$OPENRC_SERVICE_FILE"
    fi
    rm -f "$INSTALL_BIN" "$SHADOWTLS_BIN" "$SHORTCUT_BIN"
    rm_cfg=$(prompt_yesno "Also remove $CONFIG_DIR" "n")
    [ "$rm_cfg" = y ] && rm -rf "$CONFIG_DIR"
    rm -f "$MANAGER_BIN"
    print_success "Uninstalled"
}

show_help() {
    cat <<'HELP'
Usage: snell [command]

Commands:
  install        Install OpenSnell / Surge Snell
  reconfigure    Reconfigure Snell and optional ShadowTLS v3
  update         Update installed server binary (and ShadowTLS if enabled)
  uninstall      Remove services and binaries
  start          Start Snell (+ ShadowTLS when enabled)
  stop           Stop the stack
  restart        Restart the stack
  enable         Enable boot auto-start
  disable        Disable boot auto-start
  status         Show service status
  info           Show connection/client configuration
  github         Show GitHub one-line deployment commands
  github-config  Configure GitHub repo/raw source for deployment
  self-update    Update this manager script from configured GitHub source
  help           Show this help

Run `snell` with no arguments to open the interactive menu.
HELP
}

pause_menu() {
    echo
    read -r -p "Press Enter to return to menu..." _ || true
}

show_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${BOLD}${MAGENTA}=====================================================${NC}"
        echo -e "${BOLD}${MAGENTA}       Snell + ShadowTLS Management Menu             ${NC}"
        echo -e "${BOLD}${MAGENTA}=====================================================${NC}"
        echo
        echo -e "${GREEN}1)${NC}  Install"
        echo -e "${GREEN}2)${NC}  Reconfigure / ShadowTLS"
        echo -e "${GREEN}3)${NC}  Update binaries"
        echo -e "${RED}4)${NC}  Uninstall"
        echo -e "${BLUE}5)${NC}  Start"
        echo -e "${BLUE}6)${NC}  Stop"
        echo -e "${BLUE}7)${NC}  Restart"
        echo -e "${CYAN}8)${NC}  Enable auto-start"
        echo -e "${CYAN}9)${NC}  Disable auto-start"
        echo -e "${YELLOW}10)${NC} Status"
        echo -e "${YELLOW}11)${NC} Connection info"
        echo -e "${CYAN}12)${NC} GitHub quick deploy"
        echo -e "${CYAN}13)${NC} Update manager from GitHub"
        echo -e "${MAGENTA}0)${NC}  Exit"
        echo
        local choice
        read -r -p "$(echo -e "${CYAN}Choice (0-13): ${NC}")" choice
        case "$choice" in
            1) do_install; pause_menu ;;
            2) do_reconfigure; pause_menu ;;
            3) do_update; pause_menu ;;
            4) do_uninstall; return ;;
            5) check_root; start_stack; pause_menu ;;
            6) check_root; stop_stack; pause_menu ;;
            7) check_root; restart_stack; pause_menu ;;
            8) check_root; enable_stack; pause_menu ;;
            9) check_root; disable_stack; pause_menu ;;
            10) status_stack; pause_menu ;;
            11) show_info; pause_menu ;;
            12)
                if ! show_github_deploy; then
                    echo
                    local cfg
                    cfg=$(prompt_yesno "Configure GitHub source now" "y")
                    [ "$cfg" = y ] && do_github_config
                fi
                pause_menu
                ;;
            13) do_manager_self_update; pause_menu ;;
            0) return ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

main() {
    case "${1:-}" in help|--help|-h) show_help; return ;; esac
    check_linux
    detect_os
    detect_init
    case "${1:-}" in
        install) do_install ;;
        reconfigure) do_reconfigure ;;
        update|upgrade) do_update ;;
        uninstall) do_uninstall ;;
        start) check_root; start_stack ;;
        stop) check_root; stop_stack ;;
        restart) check_root; restart_stack ;;
        enable) check_root; enable_stack ;;
        disable) check_root; disable_stack ;;
        status) status_stack ;;
        info) show_info ;;
        github|github-deploy) show_github_deploy ;;
        github-config) do_github_config ;;
        self-update|manager-update) do_manager_self_update ;;
        "") show_menu ;;
        *) print_error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
