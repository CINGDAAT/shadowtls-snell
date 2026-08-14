#!/usr/bin/env bash
set -Eeuo pipefail

# Snell v5 + v6 dual-stack interactive installer for Debian and Alpine Linux.
# Official Snell binaries are closed-source. By continuing, you accept Surge's terms.

SCRIPT_VERSION="1.0.0"
SNELL_BASE_URL="https://dl.nssurge.com/snell"
SNELL_V5_PACKAGE="5.0.1"
SNELL_V6_PACKAGE="6.0.0rc2"
SHADOWTLS_VERSION="0.2.25"
SHADOWTLS_BASE_URL="https://github.com/ihciah/shadow-tls/releases/download/v${SHADOWTLS_VERSION}"

ETC_DIR="/etc/snell-dual"
BIN_DIR="/usr/local/lib/snell-dual"
META_FILE="${ETC_DIR}/install.env"
V5_BIN="${BIN_DIR}/snell-server-v5"
V6_BIN="${BIN_DIR}/snell-server-v6"
STLS_BIN="${BIN_DIR}/shadow-tls"
V5_CONF="${ETC_DIR}/snell-v5.conf"
V6_CONF="${ETC_DIR}/snell-v6.conf"

OS_ID=""
SERVICE_MANAGER=""
SNELL_ARCH=""
STLS_ARCH=""
STLS_ENABLED="false"

green='\033[32m'; yellow='\033[33m'; red='\033[31m'; reset='\033[0m'
info() { printf '%b[信息]%b %s\n' "$green" "$reset" "$*"; }
warn() { printf '%b[提示]%b %s\n' "$yellow" "$reset" "$*" >&2; }
die() { printf '%b[错误]%b %s\n' "$red" "$reset" "$*" >&2; exit 1; }

cleanup_tmp() {
  [[ -z ${WORK_DIR:-} || ! -d ${WORK_DIR:-} ]] || rm -rf -- "$WORK_DIR"
}
trap cleanup_tmp EXIT

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 或 sudo 运行。"
}

detect_platform() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian) OS_ID="debian" ;;
    alpine) OS_ID="alpine" ;;
    *) die "仅支持 Debian 与 Alpine；当前系统为 ${ID:-unknown}。" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) SNELL_ARCH="amd64"; STLS_ARCH="x86_64" ;;
    aarch64|arm64) SNELL_ARCH="aarch64"; STLS_ARCH="aarch64" ;;
    i386|i486|i586|i686) SNELL_ARCH="i386"; STLS_ARCH="" ;;
    *) die "当前架构 $(uname -m) 无法同时部署官方 Snell v5/v6。" ;;
  esac

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    SERVICE_MANAGER="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
  elif [[ $OS_ID == debian ]]; then
    SERVICE_MANAGER="systemd"
  else
    SERVICE_MANAGER="openrc"
  fi
}

install_dependencies() {
  info "安装运行依赖…"
  if [[ $OS_ID == debian ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl unzip openssl iproute2
  else
    apk add --no-cache ca-certificates curl unzip openssl iproute2 openrc
    if ! apk add --no-cache gcompat; then
      apk add --no-cache libc6-compat || die "无法安装 gcompat/libc6-compat；请检查 Alpine 软件源。"
    fi
    apk add --no-cache upx || die "无法安装 upx；请启用当前 Alpine 版本的 community 仓库后重试。"
    update-ca-certificates >/dev/null 2>&1 || true
  fi
}

prompt_default() {
  local prompt=$1 default=${2-} value
  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value
    printf '%s' "$value"
  fi
}

prompt_yes_no() {
  local prompt=$1 default=${2:-y} value suffix
  [[ $default == y ]] && suffix='Y/n' || suffix='y/N'
  while true; do
    read -r -p "$prompt [$suffix]: " value
    value=${value:-$default}
    case "$value" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

random_port() {
  local port
  for _ in $(seq 1 200); do
    port=$((10000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 50001))
    if ! ss -H -lntu 2>/dev/null | awk -v p=":$port" '$5 ~ p"$" {found=1} END{exit !found}'; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

port_is_free() {
  local port=$1
  [[ $port =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || return 1
  ! ss -H -lntu 2>/dev/null | awk -v p=":$port" '$5 ~ p"$" {found=1} END{exit !found}'
}

ask_port() {
  local label=$1 default=$2 port
  while true; do
    port=$(prompt_default "$label" "$default")
    if port_is_free "$port"; then printf '%s' "$port"; return 0; fi
    warn "端口无效或已被占用：$port"
  done
}

random_secret() { openssl rand -hex 16; }

ask_secret() {
  local label=$1 value
  while true; do
    value=$(prompt_default "$label（留空自动生成）" "")
    [[ -n $value ]] || value=$(random_secret)
    if [[ ${#value} -ge 16 && ${#value} -le 255 && $value =~ ^[A-Za-z0-9._~+-]+$ ]]; then
      printf '%s' "$value"
      return 0
    fi
    warn "请输入 16–255 位字母、数字或 . _ ~ + -。"
  done
}

detect_public_ip() {
  local ip="" url
  for url in https://api.ipify.org https://api.ip.sb/ip https://ifconfig.co/ip; do
    ip=$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s' "$ip"; return; }
  done
}

ask_endpoint() {
  local detected value
  detected=$(detect_public_ip)
  while true; do
    value=$(prompt_default "Surge 配置使用的服务器 IP/域名" "${detected:-YOUR_SERVER_IP}")
    if [[ -n $value && $value =~ ^[A-Za-z0-9._:-]+$ ]]; then printf '%s' "$value"; return; fi
    warn "地址不能为空，且不能包含空格或逗号。"
  done
}

ask_v6_mode() {
  local value
  while true; do
    value=$(prompt_default "Snell v6 mode（default/unshaped/unsafe-raw）" "default")
    case "$value" in
      default|unshaped) printf '%s' "$value"; return ;;
      unsafe-raw)
        warn "unsafe-raw 不加密流量，只能用于可信隧道。"
        if prompt_yes_no "确认使用 unsafe-raw" n; then printf '%s' "$value"; return; fi
        ;;
      *) warn "mode 只能为 default、unshaped 或 unsafe-raw。" ;;
    esac
  done
}

ask_dns_preference() {
  local value
  while true; do
    value=$(prompt_default "v6 DNS IP 偏好（default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only）" "default")
    case "$value" in
      default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) printf '%s' "$value"; return ;;
      *) warn "DNS IP 偏好值无效。" ;;
    esac
  done
}

sha_for_snell() {
  case "$1:$SNELL_ARCH" in
    5:amd64) printf '%s' '5b2e221f2c6e29b1db8e47053e1221be29d5627da807cb932b089f514a3609f0' ;;
    5:i386) printf '%s' 'd981b8ab95a38d57ca5544bf8b5d67da57955209b5edb2d8842a0ed5e21a1701' ;;
    5:aarch64) printf '%s' 'c9e1cc1f1a86e7d2958f2bc41ff9dc668edf479455a651ea05c6db2c18cd2e4e' ;;
    6:amd64) printf '%s' '27d8bead8dd7a33f2207b58c7bb6b4c274f67f537b621dcbee7112ffd22e23e6' ;;
    6:i386) printf '%s' '0c0ead54d5a94efddf04a159576e38b90b1723a2b8195a9b87ca270dc7491e55' ;;
    6:aarch64) printf '%s' '316c924cb2f7bea75278303265cf004c66379244e101c64ab672a1c987bf8041' ;;
    *) return 1 ;;
  esac
}

download_snell() {
  local major=$1 dest=$2 version url archive unpack expected actual
  [[ $major == 5 ]] && version=$SNELL_V5_PACKAGE || version=$SNELL_V6_PACKAGE
  url="${SNELL_BASE_URL}/snell-server-v${version}-linux-${SNELL_ARCH}.zip"
  archive="${WORK_DIR}/snell-v${major}.zip"
  unpack="${WORK_DIR}/unpack-v${major}"
  mkdir -p "$unpack"
  info "下载官方 Snell v${major}（${version}, ${SNELL_ARCH}）…"
  curl -fL --proto '=https' --tlsv1.2 "$url" -o "$archive"
  unzip -q "$archive" -d "$unpack"
  [[ -f $unpack/snell-server ]] || die "Snell v${major} 压缩包内容异常。"
  expected=$(sha_for_snell "$major")
  actual=$(sha256sum "$unpack/snell-server" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "Snell v${major} SHA-256 校验失败。"

  if [[ $OS_ID == alpine && $major == 5 ]]; then
    info "Alpine：正在解开 Snell v5 官方二进制的 UPX 壳…"
    upx -d "$unpack/snell-server" >/dev/null || die "Snell v5 UPX 解包失败。"
  fi
  install -m 0755 "$unpack/snell-server" "$dest"
  "$dest" -v >/dev/null 2>&1 || die "Snell v${major} 无法在当前系统运行。"
}

download_shadowtls() {
  local asset expected actual
  [[ -n $STLS_ARCH ]] || die "当前架构没有上游 ShadowTLS v3 预编译文件。"
  asset="shadow-tls-${STLS_ARCH}-unknown-linux-musl"
  case "$STLS_ARCH" in
    x86_64) expected='a173f5f2d57f45211b68e10ceeddc15b1791077b914fa89747bc705fddc71532' ;;
    aarch64) expected='3295476b37f549a68906519d3eaecb74bf3b6eaf9094cebb16ee84f0151373c6' ;;
    *) die "ShadowTLS 架构映射缺失。" ;;
  esac
  info "下载 ShadowTLS v${SHADOWTLS_VERSION}…"
  curl -fL --proto '=https' --tlsv1.2 "${SHADOWTLS_BASE_URL}/${asset}" -o "${WORK_DIR}/${asset}"
  actual=$(sha256sum "${WORK_DIR}/${asset}" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "ShadowTLS SHA-256 校验失败。"
  install -m 0755 "${WORK_DIR}/${asset}" "$STLS_BIN"
  "$STLS_BIN" --version >/dev/null 2>&1 || die "ShadowTLS 无法在当前系统运行。"
}

write_configs() {
  local v5_listen
  [[ $STLS_ENABLED == true ]] && v5_listen="127.0.0.1:${V5_INNER_PORT}" || v5_listen="0.0.0.0:${V5_PORT}"
  umask 077
  {
    printf '%s\n' '[snell-server]'
    printf 'listen = %s\n' "$v5_listen"
    printf 'psk = %s\n' "$V5_PSK"
    printf 'ipv6 = %s\n' "$V5_IPV6"
    printf '%s\n' 'version = 5'
  } > "$V5_CONF"
  {
    printf '%s\n' '[snell-server]'
    printf 'listen = 0.0.0.0:%s\n' "$V6_PORT"
    printf 'psk = %s\n' "$V6_PSK"
    printf 'mode = %s\n' "$V6_MODE"
    printf 'dns-ip-preference = %s\n' "$V6_DNS_PREF"
    printf '%s\n' 'version = 6'
  } > "$V6_CONF"
  {
    printf 'PUBLIC_ENDPOINT=%s\n' "$PUBLIC_ENDPOINT"
    printf 'V5_PORT=%s\nV5_INNER_PORT=%s\nV5_PSK=%s\nV5_IPV6=%s\n' "$V5_PORT" "$V5_INNER_PORT" "$V5_PSK" "$V5_IPV6"
    printf 'V6_PORT=%s\nV6_PSK=%s\nV6_MODE=%s\nV6_DNS_PREF=%s\n' "$V6_PORT" "$V6_PSK" "$V6_MODE" "$V6_DNS_PREF"
    printf 'STLS_ENABLED=%s\nSTLS_PORT=%s\nSTLS_PASSWORD=%s\nSTLS_SNI=%s\n' "$STLS_ENABLED" "$STLS_PORT" "$STLS_PASSWORD" "$STLS_SNI"
    printf 'CLIENT_TFO=%s\n' "$CLIENT_TFO"
  } > "$META_FILE"
  chmod 600 "$V5_CONF" "$V6_CONF" "$META_FILE"
}

write_systemd_services() {
  local systemd_dir=/etc/systemd/system stls_tfo_arg=""
  [[ ${CLIENT_TFO:-false} != true ]] || stls_tfo_arg="--fastopen"
  cat > "${systemd_dir}/snell-v5.service" <<EOF
[Unit]
Description=Snell v5 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${V5_BIN} -c ${V5_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  cat > "${systemd_dir}/snell-v6.service" <<EOF
[Unit]
Description=Snell v6 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${V6_BIN} -c ${V6_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  if [[ $STLS_ENABLED == true ]]; then
    cat > "${systemd_dir}/shadowtls-v5.service" <<EOF
[Unit]
Description=ShadowTLS v3 frontend for Snell v5
After=network-online.target snell-v5.service
Requires=snell-v5.service

[Service]
Type=simple
Environment=RUST_LOG=error
ExecStart=${STLS_BIN} ${stls_tfo_arg} --v3 server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${V5_INNER_PORT} --tls ${STLS_SNI} --password ${STLS_PASSWORD}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
  else
    rm -f "${systemd_dir}/shadowtls-v5.service"
  fi
  systemctl daemon-reload
}

write_openrc_service() {
  local name=$1 command=$2 args=$3
  cat > "/etc/init.d/${name}" <<EOF
#!/sbin/openrc-run
name="${name}"
description="${name} managed by snell-dual-manager"
command="${command}"
command_args="${args}"
command_background="yes"
pidfile="/run/${name}.pid"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.log"
rc_ulimit="-n 65536 -l unlimited"

depend() {
  need net
}
EOF
  chmod 755 "/etc/init.d/${name}"
}

write_openrc_services() {
  local stls_tfo_arg=""
  [[ ${CLIENT_TFO:-false} != true ]] || stls_tfo_arg="--fastopen"
  write_openrc_service snell-v5 "$V5_BIN" "-c $V5_CONF"
  write_openrc_service snell-v6 "$V6_BIN" "-c $V6_CONF"
  if [[ $STLS_ENABLED == true ]]; then
    write_openrc_service shadowtls-v5 "$STLS_BIN" "${stls_tfo_arg} --v3 server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${V5_INNER_PORT} --tls ${STLS_SNI} --password ${STLS_PASSWORD}"
  else
    rm -f /etc/init.d/shadowtls-v5
  fi
}

service_enable_start() {
  local name=$1
  if [[ $SERVICE_MANAGER == systemd ]]; then
    systemctl enable "${name}.service" >/dev/null
    systemctl restart "${name}.service"
    systemctl is-active --quiet "${name}.service"
  else
    rc-update add "$name" default >/dev/null
    rc-service "$name" restart >/dev/null 2>&1 || rc-service "$name" start
    rc-service "$name" status >/dev/null
  fi
}

service_stop_disable() {
  local name=$1
  if [[ $SERVICE_MANAGER == systemd ]]; then
    systemctl disable --now "${name}.service" >/dev/null 2>&1 || true
  else
    rc-service "$name" stop >/dev/null 2>&1 || true
    rc-update del "$name" default >/dev/null 2>&1 || true
  fi
}

open_firewall() {
  local v5_public tcp_ports udp_port=""
  [[ $STLS_ENABLED == true ]] && v5_public=$STLS_PORT || { v5_public=$V5_PORT; udp_port=$V5_PORT; }
  tcp_ports="$v5_public $V6_PORT"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for p in $tcp_ports; do ufw allow "$p/tcp"; done
    [[ -z $udp_port ]] || ufw allow "$udp_port/udp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $tcp_ports; do firewall-cmd --permanent --add-port="$p/tcp"; done
    [[ -z $udp_port ]] || firewall-cmd --permanent --add-port="$udp_port/udp"
    firewall-cmd --reload
  else
    warn "未检测到启用的 UFW/firewalld；请在云防火墙中放行 TCP ${v5_public}/${V6_PORT}${udp_port:+ 和 UDP $udp_port}。"
  fi
}

surge_endpoint() {
  [[ $1 == *:* && $1 != \[*\] ]] && printf '[%s]' "$1" || printf '%s' "$1"
}

load_meta() {
  [[ -r $META_FILE ]] || die "未找到安装信息：$META_FILE"
  # Values written by this script are restricted to shell-safe characters.
  # shellcheck disable=SC1090
  . "$META_FILE"
}

show_configs() {
  load_meta
  local endpoint v5_line v6_line
  endpoint=$(surge_endpoint "$PUBLIC_ENDPOINT")
  if [[ $STLS_ENABLED == true ]]; then
    v5_line="Snell-v5-STLS = snell, ${endpoint}, ${STLS_PORT}, psk=${V5_PSK}, version=5, reuse=true, tfo=${CLIENT_TFO}, block-quic=true, shadow-tls-password=${STLS_PASSWORD}, shadow-tls-sni=${STLS_SNI}, shadow-tls-version=3"
  else
    v5_line="Snell-v5 = snell, ${endpoint}, ${V5_PORT}, psk=${V5_PSK}, version=5, reuse=true, tfo=${CLIENT_TFO}, block-quic=off"
  fi
  v6_line="Snell-v6 = snell, ${endpoint}, ${V6_PORT}, psk=${V6_PSK}, version=6, mode=${V6_MODE}, reuse=true, tfo=${CLIENT_TFO}"
  printf '\n%bSurge [Proxy] 配置%b\n%s\n%s\n\n' "$green" "$reset" "$v5_line" "$v6_line"
  if [[ $STLS_ENABLED == true ]]; then
    printf 'v5 数据流：Surge → %s:%s/ShadowTLS v3 → 127.0.0.1:%s/Snell v5\n' "$PUBLIC_ENDPOINT" "$STLS_PORT" "$V5_INNER_PORT"
  else
    printf 'v5 原生端口需同时放行 TCP/UDP；block-quic=off 用于 Snell v5 QUIC 代理。\n'
  fi
  printf 'v6 当前官方服务仅监听 TCP；客户端 mode 必须与服务端一致。\n\n'
}

show_status() {
  detect_platform
  local name
  for name in snell-v5 snell-v6 shadowtls-v5; do
    [[ $name != shadowtls-v5 || -e /etc/systemd/system/shadowtls-v5.service || -e /etc/init.d/shadowtls-v5 ]] || continue
    printf '\n[%s]\n' "$name"
    if [[ $SERVICE_MANAGER == systemd ]]; then
      systemctl status "${name}.service" --no-pager -l | sed -n '1,12p' || true
    else
      rc-service "$name" status || true
    fi
  done
}

collect_install_settings() {
  local default_port answer
  printf '\n%bSnell v5 + v6 共存安装向导%b\n' "$green" "$reset"
  PUBLIC_ENDPOINT=$(ask_endpoint)
  default_port=$(random_port); V5_PORT=$(ask_port "Snell v5 公网端口" "$default_port")
  V5_PSK=$(ask_secret "Snell v5 PSK")
  if prompt_yes_no "允许 v5 出站解析/连接 IPv6" n; then V5_IPV6=true; else V5_IPV6=false; fi

  STLS_ENABLED=false; STLS_PORT=""; STLS_PASSWORD=""; STLS_SNI=""; V5_INNER_PORT="$V5_PORT"
  if prompt_yes_no "给 Snell v5 套 ShadowTLS v3" y; then
    [[ -n $STLS_ARCH ]] || die "当前 i386 架构没有 ShadowTLS 官方预编译文件。"
    STLS_ENABLED=true
    V5_INNER_PORT=$(ask_port "Snell v5 回环后端端口" "$(random_port)")
    [[ $V5_INNER_PORT != "$V5_PORT" ]] || die "回环端口不能与公网端口相同。"
    STLS_PORT=$(ask_port "ShadowTLS 公网端口" "443")
    [[ $STLS_PORT != "$V5_INNER_PORT" && $STLS_PORT != "$V5_PORT" ]] || die "端口不能重复。"
    STLS_PASSWORD=$(ask_secret "ShadowTLS 密码")
    while true; do
      STLS_SNI=$(prompt_default "ShadowTLS TLS 伪装域名" "gateway.icloud.com")
      [[ $STLS_SNI =~ ^[A-Za-z0-9.-]+$ && $STLS_SNI == *.* ]] && break
      warn "请输入合法域名。"
    done
  fi

  default_port=$(random_port); V6_PORT=$(ask_port "Snell v6 公网端口" "$default_port")
  [[ $V6_PORT != "$V5_PORT" && $V6_PORT != "${STLS_PORT:-}" && $V6_PORT != "$V5_INNER_PORT" ]] || die "v6 端口与 v5/ShadowTLS 端口重复。"
  V6_PSK=$(ask_secret "Snell v6 PSK")
  V6_MODE=$(ask_v6_mode)
  V6_DNS_PREF=$(ask_dns_preference)
  if prompt_yes_no "Surge 客户端配置启用 TFO" y; then CLIENT_TFO=true; else CLIENT_TFO=false; fi

  printf '\n部署摘要\n  系统：%s / %s / %s\n  v5：%s (%s)\n' "$OS_ID" "$SNELL_ARCH" "$SERVICE_MANAGER" "$V5_PORT" "$([[ $STLS_ENABLED == true ]] && printf '经 ShadowTLS :%s' "$STLS_PORT" || printf '原生 TCP+UDP')"
  printf '  v6：%s (mode=%s)\n  Surge 地址：%s\n' "$V6_PORT" "$V6_MODE" "$PUBLIC_ENDPOINT"
  prompt_yes_no "确认下载并部署" y || { info "已取消。"; exit 0; }
}

install_all() {
  require_root
  detect_platform
  install_dependencies
  if [[ -e $META_FILE ]] && ! prompt_yes_no "检测到既有部署，是否覆盖配置并更新二进制" n; then
    info "已取消。"
    return
  fi
  collect_install_settings
  WORK_DIR=$(mktemp -d /tmp/snell-dual.XXXXXX)
  install -d -m 0755 "$BIN_DIR"
  install -d -m 0700 "$ETC_DIR"
  download_snell 5 "$V5_BIN"
  download_snell 6 "$V6_BIN"
  [[ $STLS_ENABLED != true ]] || download_shadowtls
  write_configs
  if [[ $SERVICE_MANAGER == systemd ]]; then write_systemd_services; else write_openrc_services; fi
  service_enable_start snell-v5 || die "Snell v5 启动失败，请检查服务日志。"
  service_enable_start snell-v6 || die "Snell v6 启动失败，请检查服务日志。"
  [[ $STLS_ENABLED != true ]] || service_enable_start shadowtls-v5 || die "ShadowTLS 启动失败，请检查服务日志。"
  if prompt_yes_no "自动配置已启用的 UFW/firewalld" y; then open_firewall; fi
  info "Snell v5 与 v6 已部署并设置为开机启动。"
  show_configs
}

uninstall_all() {
  require_root
  detect_platform
  prompt_yes_no "确认删除 Snell v5/v6、ShadowTLS 服务、二进制和配置" n || { info "已取消。"; return; }
  service_stop_disable shadowtls-v5
  service_stop_disable snell-v6
  service_stop_disable snell-v5
  if [[ $SERVICE_MANAGER == systemd ]]; then
    rm -f /etc/systemd/system/snell-v5.service /etc/systemd/system/snell-v6.service /etc/systemd/system/shadowtls-v5.service
    systemctl daemon-reload
  else
    rm -f /etc/init.d/snell-v5 /etc/init.d/snell-v6 /etc/init.d/shadowtls-v5
  fi
  rm -rf -- "$ETC_DIR" "$BIN_DIR"
  info "已删除部署文件；未自动删除防火墙规则。"
}

menu() {
  local choice
  while true; do
    printf '\nSnell Dual Manager v%s\n1. 安装/覆盖 v5 + v6\n2. 输出 Surge 配置\n3. 查看服务状态\n4. 卸载\n0. 退出\n' "$SCRIPT_VERSION"
    read -r -p '请选择 [0-4]: ' choice
    case "$choice" in
      1) install_all ;;
      2) show_configs ;;
      3) show_status ;;
      4) uninstall_all ;;
      0) exit 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

case "${1:-}" in
  install) install_all ;;
  show|info) show_configs ;;
  status) show_status ;;
  uninstall) uninstall_all ;;
  -h|--help)
    printf '用法：%s [install|show|status|uninstall]\n不带参数时进入交互菜单。\n' "$0"
    ;;
  "") menu ;;
  *) die "未知参数：$1" ;;
esac
