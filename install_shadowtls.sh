#!/usr/bin/env bash
# Standalone ShadowTLS manager for an existing Snell v5 installed by the original OpenSnell script.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

BIN="/usr/local/bin/shadow-tls"
SELF_PATH="/usr/local/bin/tls"
SERVICE_NAME="shadow-tls"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_DIR="/etc/shadow-tls"
META_FILE="${CONFIG_DIR}/manager.conf"
SNELL_CONFIG="/etc/snell/snell-server.conf"
SNELL_META="/etc/snell/.install_meta"
SNELL_SERVICE="snell-server"
RELEASE_BASE="https://github.com/ihciah/shadow-tls/releases/latest/download"

print_header()  { echo; echo -e "${BOLD}${BLUE}===========================================================${NC}"; echo -e "${BOLD}${BLUE}  $1${NC}"; echo -e "${BOLD}${BLUE}===========================================================${NC}"; echo; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }

check_root() {
    [ "$(id -u)" -eq 0 ] || { print_error "This command must be run as root."; exit 1; }
}

check_linux() {
    [ "$(uname -s)" = "Linux" ] || { print_error "Linux only."; exit 1; }
    command -v systemctl >/dev/null 2>&1 || { print_error "systemd is required."; exit 1; }
}

install_self() {
    [ "$(id -u)" -eq 0 ] || return 0
    local src="${BASH_SOURCE[0]:-}"
    if [ "$src" != "$SELF_PATH" ] && [ -r "$src" ]; then
        if cat "$src" > "${SELF_PATH}.tmp" 2>/dev/null; then
            chmod 755 "${SELF_PATH}.tmp"
            mv "${SELF_PATH}.tmp" "$SELF_PATH"
            print_success "Installed shortcut: tls"
        else
            rm -f "${SELF_PATH}.tmp" 2>/dev/null || true
        fi
    fi
}

ensure_tools() {
    local missing=() t
    for t in curl openssl ss sed grep awk; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    print_info "Installing missing tools: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y curl openssl iproute2 >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl openssl iproute >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl openssl iproute >/dev/null
    else
        print_error "Unsupported package manager. Please install: curl openssl iproute2"
        exit 1
    fi
}

prompt_default() {
    local q="$1" d="$2" r
    if [ -n "$d" ]; then
        read -r -p "$(echo -e "${CYAN}${q} [${BOLD}${d}${NC}${CYAN}]: ${NC}")" r
    else
        read -r -p "$(echo -e "${CYAN}${q}: ${NC}")" r
    fi
    printf '%s' "${r:-$d}"
}

prompt_yesno() {
    local q="$1" d="$2" r
    read -r -p "$(echo -e "${CYAN}${q} (y/n) [${BOLD}${d}${NC}${CYAN}]: ${NC}")" r
    r="${r:-$d}"
    case "${r,,}" in y|yes) echo y ;; *) echo n ;; esac
}

meta_get() {
    local key="$1" file="${2:-$META_FILE}"
    [ -f "$file" ] || return 0
    sed -n "s/^${key}=//p" "$file" | head -1
}

config_get() {
    local key="$1"
    [ -f "$SNELL_CONFIG" ] || return 0
    sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$/\1/p" "$SNELL_CONFIG" | head -1 | sed -E 's/[[:space:]]+$//'
}

config_has() {
    local key="$1"
    grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$SNELL_CONFIG" 2>/dev/null
}

config_set() {
    local key="$1" value="$2"
    if config_has "$key"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$SNELL_CONFIG"
    else
        echo "${key} = ${value}" >> "$SNELL_CONFIG"
    fi
}

config_remove() {
    local key="$1"
    sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$SNELL_CONFIG"
}

snell_proto() {
    local p
    p=$(meta_get proto "$SNELL_META")
    printf '%s' "${p:-5}"
}

snell_variant() {
    meta_get variant "$SNELL_META"
}

snell_port_from_config() {
    local listen
    listen=$(config_get listen)
    printf '%s' "$listen" | sed -E 's/.*:([0-9]+)$/\1/'
}

validate_snell_v5() {
    [ -f "$SNELL_CONFIG" ] || { print_error "Snell config not found: $SNELL_CONFIG"; return 1; }
    [ -f "$SNELL_META" ] || { print_error "Snell metadata not found: $SNELL_META"; print_info "Install Snell with the s.ee/opensnell script first."; return 1; }
    local proto
    proto=$(snell_proto)
    [ "$proto" = "5" ] || { print_error "ShadowTLS manager only wraps Snell v5. Detected protocol v${proto}."; return 1; }
    local port
    port=$(meta_get port "$SNELL_META")
    [ -n "$port" ] || port=$(snell_port_from_config)
    [[ "$port" =~ ^[0-9]+$ ]] || { print_error "Could not detect Snell listen port."; return 1; }
    return 0
}

gen_password() { openssl rand -hex 16; }

get_ipv4() {
    curl -s -4 --max-time 5 https://ip.sb 2>/dev/null \
        || curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "YOUR_SERVER_IP"
}

port_is_free() {
    local p="$1"
    ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
}

pick_free_port() {
    local p
    if port_is_free 443; then echo 443; return 0; fi
    for _ in $(seq 1 100); do
        p=$((RANDOM % 50000 + 10000))
        if port_is_free "$p"; then echo "$p"; return 0; fi
    done
    return 1
}

detect_target() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        armv7l|armv7) echo "armv7-unknown-linux-musleabihf" ;;
        *) print_error "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
}

download_binary() {
    local target url tmp
    target=$(detect_target) || return 1
    url="${RELEASE_BASE}/shadow-tls-${target}"
    tmp=$(mktemp /tmp/shadow-tls.XXXXXX) || return 1
    print_info "Downloading latest ShadowTLS for ${target}..."
    if ! curl -fL --retry 3 --connect-timeout 10 "$url" -o "$tmp"; then
        rm -f "$tmp"
        print_error "Download failed: $url"
        return 1
    fi
    install -m 755 "$tmp" "$BIN"
    rm -f "$tmp"
    if "$BIN" --version >/dev/null 2>&1; then
        print_success "Installed $($BIN --version 2>/dev/null | head -1)"
    else
        print_success "Installed ShadowTLS binary: $BIN"
    fi
}

capture_snell_originals() {
    local current_listen current_obfs current_quic
    current_listen=$(config_get listen)
    current_obfs="__ABSENT__"; current_quic="__ABSENT__"
    config_has obfs && current_obfs=$(config_get obfs)
    config_has quic && current_quic=$(config_get quic)
    printf '%s\n%s\n%s\n' "$current_listen" "$current_obfs" "$current_quic"
}

force_snell_loopback() {
    local snell_port="$1"
    config_set listen "127.0.0.1:${snell_port}"
    config_set obfs "off"
    if [ "$(snell_variant)" = "opensnell" ] && config_has quic; then
        config_set quic "false"
    fi
    chmod 600 "$SNELL_CONFIG"
}

restore_snell_fields() {
    [ -f "$SNELL_CONFIG" ] || return 0
    local orig_listen orig_obfs orig_quic
    orig_listen=$(meta_get original_listen)
    orig_obfs=$(meta_get original_obfs)
    orig_quic=$(meta_get original_quic)
    [ -n "$orig_listen" ] && config_set listen "$orig_listen"
    if [ "$orig_obfs" = "__ABSENT__" ]; then config_remove obfs; elif [ -n "$orig_obfs" ]; then config_set obfs "$orig_obfs"; fi
    if [ "$orig_quic" = "__ABSENT__" ]; then config_remove quic; elif [ -n "$orig_quic" ]; then config_set quic "$orig_quic"; fi
    chmod 600 "$SNELL_CONFIG"
}

fastopen_flag() {
    local v
    v=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "")
    [ "$v" = "3" ] && echo "--fastopen" || true
}

write_service() {
    local ext_port="$1" snell_port="$2" tls_host="$3" password="$4" fastopen
    fastopen=$(fastopen_flag)
    cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=ShadowTLS v3 for Snell v5
After=network-online.target ${SNELL_SERVICE}.service
Wants=network-online.target
Requires=${SNELL_SERVICE}.service

[Service]
Type=simple
Environment=RUST_LOG=info
ExecStart=${BIN} ${fastopen:+${fastopen} }--v3 server --listen 0.0.0.0:${ext_port} --server 127.0.0.1:${snell_port} --tls ${tls_host}:443 --password ${password}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload
}

firewall_allow() {
    local port="$1" manager="none" added="false"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        manager="ufw"
        if ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${port}/tcp[[:space:]]+ALLOW"; then
            added="false"
        else
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
            added="true"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        manager="firewalld"
        if firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
            added="false"
        else
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            added="true"
        fi
    fi
    printf '%s\n%s\n' "$manager" "$added"
}

firewall_remove_if_added() {
    local port="$1" manager="$2" added="$3"
    [ "$added" = "true" ] || return 0
    case "$manager" in
        ufw) ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
    esac
}

write_meta() {
    local ext_port="$1" snell_port="$2" tls_host="$3" password="$4"
    local orig_listen="$5" orig_obfs="$6" orig_quic="$7" fw_manager="$8" fw_added="$9"
    mkdir -p "$CONFIG_DIR"
    cat > "$META_FILE" <<EOF2
manager_version=1
external_port=${ext_port}
snell_port=${snell_port}
tls_host=${tls_host}
password=${password}
protocol=3
original_listen=${orig_listen}
original_obfs=${orig_obfs}
original_quic=${orig_quic}
snell_variant=$(snell_variant)
fw_manager=${fw_manager}
fw_added=${fw_added}
EOF2
    chmod 600 "$META_FILE"
}

validate_tls_host() {
    local h="$1"
    [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$h" == *.* ]]
}

probe_tls_host() {
    local h="$1"
    if command -v timeout >/dev/null 2>&1; then
        if timeout 6 openssl s_client -connect "${h}:443" -servername "$h" </dev/null >/dev/null 2>&1; then
            print_success "TLS handshake server reachable: ${h}:443"
        else
            print_warning "Could not verify ${h}:443 from this VPS. Installation can continue, but choose a reachable TLS host if connections fail."
        fi
    fi
}

show_info() {
    [ -f "$META_FILE" ] || { print_warning "ShadowTLS is not configured."; return 1; }
    local ext_port snell_port tls_host password ip psk name tfo_param
    ext_port=$(meta_get external_port)
    snell_port=$(meta_get snell_port)
    tls_host=$(meta_get tls_host)
    password=$(meta_get password)
    ip=$(get_ipv4); [ -n "$ip" ] || ip="YOUR_SERVER_IP"
    psk=$(meta_get psk "$SNELL_META")
    name=$(meta_get node_name "$SNELL_META"); [ -n "$name" ] || name="Snell-ShadowTLS"
    tfo_param=""
    [ "$(meta_get tfo "$SNELL_META")" = "true" ] && tfo_param=", tfo=true"

    print_header "Snell v5 + ShadowTLS v3"
    echo -e "${BOLD}Server:${NC}        ${ip}:${ext_port}"
    echo -e "${BOLD}Snell backend:${NC} 127.0.0.1:${snell_port}"
    echo -e "${BOLD}Snell PSK:${NC}     ${psk}"
    echo -e "${BOLD}TLS password:${NC}  ${password}"
    echo -e "${BOLD}TLS SNI:${NC}       ${tls_host}"
    echo -e "${BOLD}ShadowTLS:${NC}     v3"
    echo
    echo -e "${YELLOW}Recommended Surge line (v5 server + v4 client; avoids Snell v5 QUIC Proxy):${NC}"
    echo -e "${GREEN}${name} = snell, ${ip}, ${ext_port}, psk=\"${psk}\", version=4, reuse=true${tfo_param}, shadow-tls-password=\"${password}\", shadow-tls-version=3, shadow-tls-sni=${tls_host}${NC}"
    echo
    echo -e "${YELLOW}If you explicitly want Snell client version=5:${NC}"
    echo -e "${GREEN}${name} = snell, ${ip}, ${ext_port}, psk=\"${psk}\", version=5, reuse=true${tfo_param}, shadow-tls-password=\"${password}\", shadow-tls-version=3, shadow-tls-sni=${tls_host}${NC}"
    echo
    systemctl is-active --quiet "$SNELL_SERVICE" && print_success "snell-server is running" || print_warning "snell-server is not running"
    systemctl is-active --quiet "$SERVICE_NAME" && print_success "shadow-tls is running" || print_warning "shadow-tls is not running"
}

do_install() {
    check_root; ensure_tools; validate_snell_v5 || exit 1
    if [ -f "$META_FILE" ]; then
        print_warning "ShadowTLS is already configured. Use Reconfigure instead."
        show_info
        return 0
    fi

    download_binary || exit 1

    local snell_port ext_default ext_port tls_host password originals orig_listen orig_obfs orig_quic fw fw_manager fw_added
    snell_port=$(meta_get port "$SNELL_META"); [ -n "$snell_port" ] || snell_port=$(snell_port_from_config)
    ext_default=$(pick_free_port) || { print_error "Could not find a free TCP port."; exit 1; }
    ext_port=$(prompt_default "ShadowTLS public listen port" "$ext_default")
    [[ "$ext_port" =~ ^[0-9]+$ ]] && [ "$ext_port" -ge 1 ] && [ "$ext_port" -le 65535 ] || { print_error "Invalid port."; exit 1; }
    [ "$ext_port" != "$snell_port" ] || { print_error "ShadowTLS public port must differ from the Snell backend port."; exit 1; }
    port_is_free "$ext_port" || { print_error "TCP port ${ext_port} is already in use."; exit 1; }

    tls_host=$(prompt_default "TLS handshake/SNI host" "www.microsoft.com")
    validate_tls_host "$tls_host" || { print_error "Use a hostname such as www.microsoft.com (no scheme/path/port)."; exit 1; }
    probe_tls_host "$tls_host"
    password=$(prompt_default "ShadowTLS password (blank = random)" "")
    [ -n "$password" ] || { password=$(gen_password); print_info "Generated TLS password: ${BOLD}${password}${NC}"; }
    [[ "$password" =~ ^[A-Za-z0-9._~-]+$ ]] || { print_error "For safe systemd parsing, password may only contain letters, numbers, . _ ~ -"; exit 1; }

    mapfile -t originals < <(capture_snell_originals)
    orig_listen="${originals[0]:-}"
    orig_obfs="${originals[1]:-__ABSENT__}"
    orig_quic="${originals[2]:-__ABSENT__}"

    print_info "Binding Snell to loopback only: 127.0.0.1:${snell_port}"
    force_snell_loopback "$snell_port"
    if ! systemctl restart "$SNELL_SERVICE"; then
        print_error "Snell failed after loopback rebind. Restoring original config."
        config_set listen "$orig_listen"
        [ "$orig_obfs" = "__ABSENT__" ] && config_remove obfs || config_set obfs "$orig_obfs"
        [ "$orig_quic" = "__ABSENT__" ] && config_remove quic || config_set quic "$orig_quic"
        systemctl restart "$SNELL_SERVICE" || true
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    write_service "$ext_port" "$snell_port" "$tls_host" "$password"
    mapfile -t fw < <(firewall_allow "$ext_port")
    fw_manager="${fw[0]:-none}"; fw_added="${fw[1]:-false}"
    write_meta "$ext_port" "$snell_port" "$tls_host" "$password" "$orig_listen" "$orig_obfs" "$orig_quic" "$fw_manager" "$fw_added"

    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if systemctl restart "$SERVICE_NAME" && sleep 1 && systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "ShadowTLS is running."
    else
        print_error "ShadowTLS failed to start; rolling Snell back to its original listener."
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        restore_snell_fields
        systemctl restart "$SNELL_SERVICE" || true
        firewall_remove_if_added "$ext_port" "$fw_manager" "$fw_added"
        rm -f "$META_FILE"
        exit 1
    fi
    show_info
}

do_reconfigure() {
    check_root; ensure_tools
    [ -f "$META_FILE" ] || { print_error "Install ShadowTLS first."; exit 1; }
    validate_snell_v5 || exit 1

    local old_port snell_port old_host old_password ext_port tls_host password old_fw_manager old_fw_added fw fw_manager fw_added
    old_port=$(meta_get external_port)
    snell_port=$(meta_get port "$SNELL_META"); [ -n "$snell_port" ] || snell_port=$(snell_port_from_config)
    old_host=$(meta_get tls_host)
    old_password=$(meta_get password)
    old_fw_manager=$(meta_get fw_manager); old_fw_added=$(meta_get fw_added)

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    ext_port=$(prompt_default "ShadowTLS public listen port" "$old_port")
    [[ "$ext_port" =~ ^[0-9]+$ ]] && [ "$ext_port" -ge 1 ] && [ "$ext_port" -le 65535 ] || { print_error "Invalid port."; exit 1; }
    [ "$ext_port" != "$snell_port" ] || { print_error "Public port must differ from Snell backend port."; exit 1; }
    if [ "$ext_port" != "$old_port" ]; then
        port_is_free "$ext_port" || { print_error "TCP port ${ext_port} is already in use."; systemctl start "$SERVICE_NAME" || true; exit 1; }
    fi
    tls_host=$(prompt_default "TLS handshake/SNI host" "$old_host")
    validate_tls_host "$tls_host" || { print_error "Invalid TLS hostname."; systemctl start "$SERVICE_NAME" || true; exit 1; }
    password=$(prompt_default "ShadowTLS password" "$old_password")
    [[ "$password" =~ ^[A-Za-z0-9._~-]+$ ]] || { print_error "Password contains unsupported characters."; systemctl start "$SERVICE_NAME" || true; exit 1; }
    probe_tls_host "$tls_host"

    force_snell_loopback "$snell_port"
    systemctl restart "$SNELL_SERVICE" || { print_error "Snell failed to restart."; exit 1; }
    write_service "$ext_port" "$snell_port" "$tls_host" "$password"

    fw_manager="$old_fw_manager"; fw_added="$old_fw_added"
    if [ "$ext_port" != "$old_port" ]; then
        firewall_remove_if_added "$old_port" "$old_fw_manager" "$old_fw_added"
        mapfile -t fw < <(firewall_allow "$ext_port")
        fw_manager="${fw[0]:-none}"; fw_added="${fw[1]:-false}"
    fi
    write_meta "$ext_port" "$snell_port" "$tls_host" "$password" \
        "$(meta_get original_listen)" "$(meta_get original_obfs)" "$(meta_get original_quic)" "$fw_manager" "$fw_added"

    systemctl restart "$SERVICE_NAME"
    show_info
}

do_update() {
    check_root; ensure_tools
    download_binary || exit 1
    if [ -f "$META_FILE" ]; then
        local ext_port snell_port tls_host password
        ext_port=$(meta_get external_port); snell_port=$(meta_get snell_port); tls_host=$(meta_get tls_host); password=$(meta_get password)
        write_service "$ext_port" "$snell_port" "$tls_host" "$password"
        systemctl restart "$SERVICE_NAME" || true
    fi
}

do_uninstall() {
    check_root
    [ -f "$META_FILE" ] || { print_warning "ShadowTLS is not configured."; return 0; }
    local confirm ext_port fw_manager fw_added
    confirm=$(prompt_yesno "Remove ShadowTLS and restore Snell's original listener?" "y")
    [ "$confirm" = "y" ] || { print_info "Aborted."; return 0; }
    ext_port=$(meta_get external_port); fw_manager=$(meta_get fw_manager); fw_added=$(meta_get fw_added)
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    firewall_remove_if_added "$ext_port" "$fw_manager" "$fw_added"
    restore_snell_fields
    systemctl restart "$SNELL_SERVICE" 2>/dev/null || true
    rm -f "$BIN"
    rm -rf "$CONFIG_DIR"
    print_success "ShadowTLS removed and Snell listener restored."
    print_info "The 'tls' manager shortcut is intentionally kept. Use 'tls remove-shortcut' to delete it."
}

reconcile_snell() {
    check_root
    [ -f "$META_FILE" ] || return 0
    if ! validate_snell_v5 >/dev/null 2>&1; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        print_warning "ShadowTLS stopped because a compatible Snell v5 installation was not found."
        return 0
    fi

    local current_listen snell_port current_obfs current_quic ext_port tls_host password
    current_listen=$(config_get listen)
    snell_port=$(meta_get port "$SNELL_META"); [ -n "$snell_port" ] || snell_port=$(snell_port_from_config)

    # If the Snell manager rewrote a public-facing config, treat those values as
    # the new originals so uninstall can restore the user's latest Snell choices.
    if [[ "$current_listen" != 127.0.0.1:* ]]; then
        current_obfs="__ABSENT__"; current_quic="__ABSENT__"
        config_has obfs && current_obfs=$(config_get obfs)
        config_has quic && current_quic=$(config_get quic)
        local old_ext old_host old_pass fw_manager fw_added
        old_ext=$(meta_get external_port); old_host=$(meta_get tls_host); old_pass=$(meta_get password)
        fw_manager=$(meta_get fw_manager); fw_added=$(meta_get fw_added)
        write_meta "$old_ext" "$snell_port" "$old_host" "$old_pass" "$current_listen" "$current_obfs" "$current_quic" "$fw_manager" "$fw_added"
        print_info "Detected Snell reconfiguration; re-applying ShadowTLS loopback binding."
    fi

    force_snell_loopback "$snell_port"
    systemctl restart "$SNELL_SERVICE" >/dev/null 2>&1 || {
        print_warning "Could not restart Snell after ShadowTLS reconciliation."
        return 1
    }
    ext_port=$(meta_get external_port); tls_host=$(meta_get tls_host); password=$(meta_get password)
    # Keep the backend port synchronized if Snell was reconfigured.
    local orig_listen orig_obfs orig_quic fw_manager fw_added
    orig_listen=$(meta_get original_listen); orig_obfs=$(meta_get original_obfs); orig_quic=$(meta_get original_quic)
    fw_manager=$(meta_get fw_manager); fw_added=$(meta_get fw_added)
    write_meta "$ext_port" "$snell_port" "$tls_host" "$password" "$orig_listen" "$orig_obfs" "$orig_quic" "$fw_manager" "$fw_added"
    write_service "$ext_port" "$snell_port" "$tls_host" "$password"
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || print_warning "ShadowTLS failed to restart after Snell changes."
}

status_service() {
    print_header "ShadowTLS Status"
    systemctl status "$SERVICE_NAME" --no-pager 2>&1 | head -20 || true
    echo
    print_header "Snell Status"
    systemctl status "$SNELL_SERVICE" --no-pager 2>&1 | head -15 || true
}

start_service()   { check_root; systemctl start "$SNELL_SERVICE"; systemctl start "$SERVICE_NAME" && print_success "ShadowTLS started"; }
stop_service()    { check_root; systemctl stop "$SERVICE_NAME" && print_success "ShadowTLS stopped"; }
restart_service() { check_root; systemctl restart "$SNELL_SERVICE"; systemctl restart "$SERVICE_NAME" && print_success "ShadowTLS restarted"; }
enable_service()  { check_root; systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 && print_success "ShadowTLS auto-start enabled"; }
disable_service() { check_root; systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 && print_success "ShadowTLS auto-start disabled"; }

show_menu() {
    echo -e "${BOLD}${MAGENTA}=====================================================${NC}"
    echo -e "${BOLD}${MAGENTA}       Snell v5 + ShadowTLS v3 Manager               ${NC}"
    echo -e "${BOLD}${MAGENTA}=====================================================${NC}"
    echo
    echo -e "${GREEN}1)${NC}  Install / attach to Snell v5"
    echo -e "${GREEN}2)${NC}  Reconfigure ShadowTLS"
    echo -e "${GREEN}3)${NC}  Update ShadowTLS binary"
    echo -e "${RED}4)${NC}  Uninstall ShadowTLS + restore Snell"
    echo -e "${BLUE}5)${NC}  Start"
    echo -e "${BLUE}6)${NC}  Stop"
    echo -e "${BLUE}7)${NC}  Restart"
    echo -e "${CYAN}8)${NC}  Enable auto-start"
    echo -e "${CYAN}9)${NC}  Disable auto-start"
    echo -e "${YELLOW}10)${NC} Show status"
    echo -e "${YELLOW}11)${NC} Show connection info"
    echo -e "${MAGENTA}0)${NC}  Exit"
    echo
    local choice
    read -r -p "$(echo -e "${CYAN}Enter your choice (0-11): ${NC}")" choice
    case "$choice" in
        1) do_install ;;
        2) do_reconfigure ;;
        3) do_update ;;
        4) do_uninstall ;;
        5) start_service ;;
        6) stop_service ;;
        7) restart_service ;;
        8) enable_service ;;
        9) disable_service ;;
        10) status_service ;;
        11) show_info ;;
        0) exit 0 ;;
        *) print_error "Invalid option"; exit 1 ;;
    esac
}

show_help() {
    cat <<EOF2
ShadowTLS manager for Snell v5

Usage: tls [command]
  install        Install latest ShadowTLS and wrap existing Snell v5
  reconfigure    Change public port / SNI / ShadowTLS password
  update         Update ShadowTLS binary from the official latest release
  uninstall      Remove ShadowTLS and restore Snell's original listener
  start|stop|restart|enable|disable|status|info
  reconcile-snell  Re-sync ShadowTLS after Snell is reconfigured
  remove-shortcut Remove /usr/local/bin/tls (only when ShadowTLS is uninstalled)
  help

Run 'tls' with no arguments for the menu.
EOF2
}

main() {
    case "${1:-}" in help|--help|-h) show_help; return 0 ;; esac
    check_linux
    install_self
    case "${1:-}" in
        install) do_install ;;
        reconfigure) do_reconfigure ;;
        update|upgrade) do_update ;;
        uninstall) do_uninstall ;;
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        enable) enable_service ;;
        disable) disable_service ;;
        status) status_service ;;
        info) show_info ;;
        reconcile-snell) reconcile_snell ;;
        remove-shortcut)
            check_root
            if [ -f "$META_FILE" ]; then print_error "Uninstall ShadowTLS first."; exit 1; fi
            rm -f "$SELF_PATH"
            print_success "Removed $SELF_PATH"
            ;;
        "") check_root; ensure_tools; show_menu ;;
        *) print_error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
