#!/usr/bin/env bash
# Interactive Snell v5/v6 + ShadowTLS manager for Debian and Alpine Linux.
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077

readonly APP_NAME="snell-stack"
readonly CONFIG_DIR="/etc/${APP_NAME}"
readonly BIN_DIR="/usr/local/lib/${APP_NAME}"
readonly LOG_DIR="/var/log/${APP_NAME}"
readonly META_FILE="${CONFIG_DIR}/meta"
readonly SURGE_BASE_URL="https://dl.nssurge.com/snell"
readonly SURGE_V5_VERSION="${SNELL_V5_VERSION:-v5.0.1}"
# Current official v6 release candidate. v6 prereleases may be wire-incompatible,
# so the Surge client must also be kept current. Advanced users can override it.
readonly SURGE_V6_VERSION="${SNELL_V6_VERSION:-v6.0.0rc2}"
readonly SHADOWTLS_API="https://api.github.com/repos/ihciah/shadow-tls/releases/latest"

OS_ID=""
INIT_SYSTEM=""
SURGE_ARCH=""
SHADOWTLS_ARCH=""

if [[ -t 1 ]]; then
  C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
  C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

info() { printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
header() { printf '\n%b%s%b\n\n' "$C_BOLD" "$*" "$C_RESET"; }

on_error() {
  local rc=$?
  printf '%b[FAIL]%b 第 %s 行执行失败（退出码 %s）。\n' "$C_RED" "$C_RESET" "${BASH_LINENO[0]:-?}" "$rc" >&2
  exit "$rc"
}
trap on_error ERR

require_root() {
  [[ $(id -u) -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

detect_platform() {
  [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-}
  case "$OS_ID" in
    debian) INIT_SYSTEM="systemd" ;;
    alpine) INIT_SYSTEM="openrc" ;;
    *) die "仅支持 Debian 和 Alpine；当前系统：${PRETTY_NAME:-$OS_ID}" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) SURGE_ARCH="amd64"; SHADOWTLS_ARCH="x86_64" ;;
    aarch64|arm64) SURGE_ARCH="aarch64"; SHADOWTLS_ARCH="aarch64" ;;
    i386|i486|i586|i686) SURGE_ARCH="i386"; SHADOWTLS_ARCH="i686" ;;
    armv7l|armv7) SURGE_ARCH="armv7l"; SHADOWTLS_ARCH="armv7" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

install_dependencies() {
  info "检查安装依赖..."
  if [[ "$OS_ID" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl unzip openssl procps >/dev/null
  else
    apk add --no-cache bash ca-certificates curl unzip openssl procps >/dev/null
  fi
  mkdir -p "$CONFIG_DIR" "$BIN_DIR" "$LOG_DIR"
  chmod 700 "$CONFIG_DIR"
  install_manager_command
}

install_manager_command() {
  local source_path=$0 target="/usr/local/bin/snell"
  if [[ -r "$source_path" ]]; then
    install -m 0755 "$source_path" "${target}.new"
    mv "${target}.new" "$target"
    ok "管理命令已安装：以后直接输入 snell 即可。"
  else
    warn "当前启动方式无法读取脚本自身，未创建 snell 快捷命令。"
  fi
}

prompt() {
  local message=$1 default=${2-} reply
  if [[ -n "$default" ]]; then
    read -r -p "$message [$default]: " reply </dev/tty
    printf '%s' "${reply:-$default}"
  else
    read -r -p "$message: " reply </dev/tty
    printf '%s' "$reply"
  fi
}

yes_no() {
  local message=$1 default=${2:-y} reply hint
  [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p "$message [$hint]: " reply </dev/tty
    reply=${reply:-$default}
    case "${reply,,}" in y|yes) return 0 ;; n|no) return 1 ;; esac
    warn "请输入 y 或 n。"
  done
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

port_in_use() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|[.:])${port}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|[.:])${port}$"
  else
    return 1
  fi
}

random_port() {
  local port i
  for ((i=0; i<100; i++)); do
    port=$((10000 + $(od -An -N2 -tu2 /dev/urandom) % 50001))
    port_in_use "$port" || { printf '%s' "$port"; return; }
  done
  die "无法找到空闲随机端口。"
}

ask_port() {
  local label=$1 default=$2 port
  while true; do
    port=$(prompt "$label" "$default")
    valid_port "$port" || { warn "端口必须为 1-65535。"; continue; }
    if port_in_use "$port"; then
      yes_no "端口 $port 似乎已被占用，仍然使用吗？" n || continue
    fi
    printf '%s' "$port"
    return
  done
}

generate_secret() { openssl rand -base64 36 | tr -d '=+/\n' | cut -c1-32; }

ask_secret() {
  local label=$1 min_len=${2:-1} value length
  while true; do
    value=$(prompt "$label（留空自动生成）" "")
    [[ -n "$value" ]] || value=$(generate_secret)
    length=$(printf '%s' "$value" | wc -c | tr -d ' ')
    if (( length < min_len || length > 255 )); then
      warn "长度必须为 ${min_len}-255 字节。"
      continue
    fi
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { warn "密钥不能包含换行。"; continue; }
    printf '%s' "$value"
    return
  done
}

save_meta() {
  local key=$1 value=$2 tmp
  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp "${CONFIG_DIR}/meta.XXXXXX")
  if [[ -f "$META_FILE" ]]; then grep -v "^${key}=" "$META_FILE" >"$tmp" || true; fi
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$META_FILE"
}

get_meta() {
  local key=$1
  [[ -f "$META_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$META_FILE" | tail -n1
}

download_surge() {
  local proto=$1 version url workdir target
  [[ "$proto" == "6" && "$SURGE_ARCH" == "armv7l" ]] && die "官方 Snell v6 未提供 armv7l 构建。"
  version=$([[ "$proto" == "5" ]] && printf '%s' "$SURGE_V5_VERSION" || printf '%s' "$SURGE_V6_VERSION")
  url="${SURGE_BASE_URL}/snell-server-${version}-linux-${SURGE_ARCH}.zip"
  target="${BIN_DIR}/snell-server-v${proto}"
  workdir=$(mktemp -d)
  info "下载官方 snell-server ${version} (${SURGE_ARCH})..."
  if ! curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "${workdir}/snell.zip" "$url"; then
    rm -rf "$workdir"
    die "下载失败：$url"
  fi
  unzip -q "${workdir}/snell.zip" -d "$workdir"
  [[ -f "${workdir}/snell-server" ]] || { rm -rf "$workdir"; die "压缩包内未找到 snell-server。"; }
  install -m 0755 "${workdir}/snell-server" "${target}.new"
  mv "${target}.new" "$target"
  rm -rf "$workdir"
  save_meta "v${proto}_version" "$version"
  ok "Snell v${proto} 二进制已安装。"
}

download_shadowtls() {
  local json urls url workdir asset
  info "查询 ShadowTLS 最新版本..."
  json=$(curl -fsSL --retry 3 --connect-timeout 15 "$SHADOWTLS_API") || die "无法查询 ShadowTLS release。"
  urls=$(printf '%s\n' "$json" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  url=$(printf '%s\n' "$urls" | grep -Ei "${SHADOWTLS_ARCH}.*unknown-linux-musl" | head -n1 || true)
  [[ -n "$url" ]] || url=$(printf '%s\n' "$urls" | grep -Ei "${SHADOWTLS_ARCH}.*linux" | head -n1 || true)
  [[ -n "$url" ]] || die "最新 release 没有适合 ${SHADOWTLS_ARCH} 的 Linux 构建。"
  workdir=$(mktemp -d)
  asset="${workdir}/$(basename "$url")"
  curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$asset" "$url" || { rm -rf "$workdir"; die "ShadowTLS 下载失败。"; }
  case "$asset" in
    *.tar.gz|*.tgz) tar -xzf "$asset" -C "$workdir" ;;
    *.zip) unzip -q "$asset" -d "$workdir" ;;
  esac
  local candidate
  candidate=$(find "$workdir" -type f -name 'shadow-tls*' ! -name '*.zip' ! -name '*.gz' | head -n1 || true)
  [[ -n "$candidate" ]] || candidate="$asset"
  install -m 0755 "$candidate" "${BIN_DIR}/shadow-tls.new"
  mv "${BIN_DIR}/shadow-tls.new" "${BIN_DIR}/shadow-tls"
  rm -rf "$workdir"
  save_meta shadowtls_version "$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  ok "ShadowTLS 已安装。"
}

service_exists() {
  local name=$1
  [[ "$INIT_SYSTEM" == "systemd" ]] && [[ -f "/etc/systemd/system/${name}.service" ]] && return 0
  [[ "$INIT_SYSTEM" == "openrc" ]] && [[ -f "/etc/init.d/${name}" ]] && return 0
  return 1
}

service_action() {
  local action=$1 name=$2
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    case "$action" in
      enable) systemctl enable "$name" >/dev/null ;;
      disable) systemctl disable "$name" >/dev/null 2>&1 || true ;;
      *) systemctl "$action" "$name" ;;
    esac
  else
    case "$action" in
      enable) rc-update add "$name" default >/dev/null ;;
      disable) rc-update del "$name" default >/dev/null 2>&1 || true ;;
      status) rc-service "$name" status || true ;;
      *) rc-service "$name" "$action" ;;
    esac
  fi
}

reload_init() { [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl daemon-reload || true; }

write_service() {
  local name=$1 description=$2 command=$3 args=$4 dependency=${5-}
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    local requires=""
    [[ -n "$dependency" ]] && requires="Requires=${dependency}.service\nAfter=${dependency}.service"
    install -m 0644 /dev/null "/etc/systemd/system/${name}.service"
    printf '[Unit]\nDescription=%s\nAfter=network-online.target\nWants=network-online.target\n%b\n\n[Service]\nType=simple\nExecStart=%s %s\nRestart=on-failure\nRestartSec=2s\nLimitNOFILE=1048576\nNoNewPrivileges=true\n\n[Install]\nWantedBy=multi-user.target\n' \
      "$description" "$requires" "$command" "$args" >"/etc/systemd/system/${name}.service"
  else
    install -m 0755 /dev/null "/etc/init.d/${name}"
    printf '#!/sbin/openrc-run\nname="%s"\ndescription="%s"\ncommand="%s"\ncommand_args="%s"\ncommand_background="yes"\npidfile="/run/${RC_SVCNAME}.pid"\noutput_log="%s/%s.log"\nerror_log="%s/%s.err"\ndepend() { need net; %s }\nstart_pre() { checkpath --directory --mode 0755 "%s"; }\n' \
      "$name" "$description" "$command" "$args" "$LOG_DIR" "$name" "$LOG_DIR" "$name" \
      "${dependency:+need $dependency;}" "$LOG_DIR" >"/etc/init.d/${name}"
  fi
  reload_init
  service_action enable "$name"
}

stop_if_exists() {
  local name=$1
  service_exists "$name" || return 0
  service_action stop "$name" >/dev/null 2>&1 || true
}

configure_v5() {
  local with_stls=${1:-ask} internal_port public_port psk ipv6_choice ipv6
  header "配置 Snell v5"
  if [[ "$with_stls" == "ask" ]]; then
    yes_no "是否为 Snell v5 前置 ShadowTLS v3？" y && with_stls="yes" || with_stls="no"
  fi
  psk=$(ask_secret "Snell v5 PSK" 1)
  yes_no "允许服务端出站使用 IPv6？" y && ipv6="true" || ipv6="false"
  if [[ "$with_stls" == "yes" ]]; then
    internal_port=$(ask_port "Snell v5 回环端口" "$(random_port)")
    public_port=$(ask_port "ShadowTLS 公网端口" "443")
  else
    public_port=$(ask_port "Snell v5 公网端口" "$(random_port)")
    internal_port=$public_port
  fi

  cat >"${CONFIG_DIR}/snell-v5.conf" <<EOF
[snell-server]
listen = $([[ "$with_stls" == "yes" ]] && printf '127.0.0.1' || printf '0.0.0.0'):${internal_port}
psk = ${psk}
obfs = off
ipv6 = ${ipv6}
EOF
  chmod 600 "${CONFIG_DIR}/snell-v5.conf"
  save_meta v5_psk "$psk"; save_meta v5_port "$public_port"; save_meta v5_internal_port "$internal_port"
  save_meta v5_shadowtls "$with_stls"; save_meta v5_ipv6 "$ipv6"
  write_service snell-v5 "Snell v5 Server" "${BIN_DIR}/snell-server-v5" "-c ${CONFIG_DIR}/snell-v5.conf"

  if [[ "$with_stls" == "yes" ]]; then
    configure_shadowtls "$internal_port" "$public_port"
  else
    remove_service shadowtls-snell-v5
    warn "v5 直接暴露；如需 ShadowTLS，可稍后从主菜单启用。"
  fi
  service_action restart snell-v5
  [[ "$with_stls" == "yes" ]] && service_action restart shadowtls-snell-v5
  ok "Snell v5 配置完成。"
}

configure_shadowtls() {
  local internal_port=${1:-$(get_meta v5_internal_port)} public_port=${2:-443} sni password
  [[ -f "${CONFIG_DIR}/snell-v5.conf" ]] || die "请先安装 Snell v5。"
  [[ -n "$internal_port" ]] || internal_port=$(ask_port "Snell v5 回环端口" "$(random_port)")
  public_port=$(ask_port "ShadowTLS 公网端口" "$public_port")
  while true; do
    sni=$(prompt "TLS 握手站点（域名，需支持 TLS 1.3）" "www.microsoft.com")
    [[ "$sni" =~ ^[A-Za-z0-9.-]+$ && "$sni" == *.* ]] && break
    warn "请输入普通域名，不要包含协议、路径或端口。"
  done
  while true; do
    password=$(ask_secret "ShadowTLS 密码" 8)
    [[ "$password" =~ ^[A-Za-z0-9_-]+$ ]] && break
    warn "为保证服务参数安全，ShadowTLS 密码仅允许字母、数字、下划线和连字符。"
  done
  download_shadowtls
  save_meta v5_shadowtls yes; save_meta v5_port "$public_port"; save_meta v5_internal_port "$internal_port"
  save_meta shadowtls_sni "$sni"; save_meta shadowtls_password "$password"
  sed -i "s|^[[:space:]]*listen[[:space:]]*=.*|listen = 127.0.0.1:${internal_port}|" "${CONFIG_DIR}/snell-v5.conf"
  cat >"${BIN_DIR}/run-shadowtls" <<EOF
#!/usr/bin/env bash
exec "${BIN_DIR}/shadow-tls" --v3 server --listen "0.0.0.0:${public_port}" --server "127.0.0.1:${internal_port}" --tls "${sni}:443" --password "${password}"
EOF
  chmod 700 "${BIN_DIR}/run-shadowtls"
  write_service shadowtls-snell-v5 "ShadowTLS v3 for Snell v5" "${BIN_DIR}/run-shadowtls" "" snell-v5
  service_action restart snell-v5
}

configure_v6() {
  local port psk mode dns_pref dns_servers egress
  header "配置 Snell v6"
  port=$(ask_port "Snell v6 公网端口" "$(random_port)")
  psk=$(ask_secret "Snell v6 PSK" 16)
  while true; do
    mode=$(prompt "模式（default/unshaped/unsafe-raw）" "default")
    case "$mode" in default|unshaped) break ;; unsafe-raw) warn "unsafe-raw 为明文，仅限可信隧道。"; yes_no "确认使用？" n && break ;; *) warn "无效模式。" ;; esac
  done
  while true; do
    dns_pref=$(prompt "DNS 偏好（default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only）" "ipv4-only")
    case "$dns_pref" in default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) break ;; *) warn "无效 DNS 偏好。" ;; esac
  done
  dns_servers=$(prompt "自定义 DNS（逗号分隔，留空使用系统 DNS）" "")
  egress=$(prompt "出站网卡（留空使用默认路由）" "")
  cat >"${CONFIG_DIR}/snell-v6.conf" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
mode = ${mode}
dns-ip-preference = ${dns_pref}
EOF
  [[ -n "$dns_servers" ]] && printf 'dns = %s\n' "$dns_servers" >>"${CONFIG_DIR}/snell-v6.conf"
  [[ -n "$egress" ]] && printf 'egress-interface = %s\n' "$egress" >>"${CONFIG_DIR}/snell-v6.conf"
  chmod 600 "${CONFIG_DIR}/snell-v6.conf"
  save_meta v6_psk "$psk"; save_meta v6_port "$port"; save_meta v6_mode "$mode"; save_meta v6_dns_pref "$dns_pref"
  write_service snell-v6 "Snell v6 Server" "${BIN_DIR}/snell-server-v6" "-c ${CONFIG_DIR}/snell-v6.conf"
  service_action restart snell-v6
  ok "Snell v6 配置完成。"
}

install_v5() { install_dependencies; download_surge 5; configure_v5; show_info; }
install_v6() { install_dependencies; download_surge 6; configure_v6; show_info; }

install_both() {
  install_dependencies
  download_surge 5
  download_surge 6
  configure_v5
  configure_v6
  show_info
}

public_ip() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || printf '<服务器IP>'
}

show_info() {
  local ip v5_psk v5_port stls sni stls_pass v6_psk v6_port v6_mode v5_version v6_version v6_extra
  ip=$(public_ip); v5_psk=$(get_meta v5_psk); v5_port=$(get_meta v5_port); stls=$(get_meta v5_shadowtls)
  sni=$(get_meta shadowtls_sni); stls_pass=$(get_meta shadowtls_password)
  v6_psk=$(get_meta v6_psk); v6_port=$(get_meta v6_port); v6_mode=$(get_meta v6_mode)
  v5_version=$(get_meta v5_version); v6_version=$(get_meta v6_version)
  header "客户端参数"
  if [[ -n "$v5_psk" ]]; then
    printf 'Snell v5（服务端 %s）:\n  server: %s:%s\n  psk: %s\n  version: 5\n  obfs: off\n' "${v5_version:-$SURGE_V5_VERSION}" "$ip" "$v5_port" "$v5_psk"
    if [[ "$stls" == "yes" ]]; then
      printf '  ShadowTLS: v3\n  ShadowTLS SNI: %s\n  ShadowTLS password: %s\n  提示: ShadowTLS 是 TCP 前置层，客户端请关闭 Snell QUIC（block-quic=on）。\n' "$sni" "$stls_pass"
      printf '\n[Surge 可直接复制]\nSnell-v5-STLS = snell, %s, %s, psk=%s, version=5, reuse=true, tfo=false, block-quic=on, shadow-tls-password=%s, shadow-tls-version=3, shadow-tls-sni=%s\n' \
        "$ip" "$v5_port" "$v5_psk" "$stls_pass" "$sni"
    else
      printf '\n[Surge 可直接复制]\nSnell-v5 = snell, %s, %s, psk=%s, version=5, reuse=true, tfo=false\n' "$ip" "$v5_port" "$v5_psk"
    fi
    printf '\n'
  fi
  if [[ -n "$v6_psk" ]]; then
    v6_extra=""
    [[ -n "$v6_mode" && "$v6_mode" != "default" ]] && v6_extra=", mode=${v6_mode}"
    printf 'Snell v6（服务端 %s）:\n  server: %s:%s\n  psk: %s\n  version: 6\n  mode: %s\n' \
      "${v6_version:-$SURGE_V6_VERSION}" "$ip" "$v6_port" "$v6_psk" "${v6_mode:-default}"
    printf '\n[Surge 可直接复制]\nSnell-v6 = snell, %s, %s, psk=%s, version=6%s, tfo=false\n\n' \
      "$ip" "$v6_port" "$v6_psk" "$v6_extra"
    warn "Snell v6 客户端与服务端必须同步兼容；服务端为 ${SURGE_V6_VERSION}，请使用最新版 Surge。"
  fi
  warn "请只放行对外端口；不要放行 v5 的回环端口。"
}

status_all() {
  header "服务状态"
  local name
  for name in snell-v5 shadowtls-snell-v5 snell-v6; do
    if service_exists "$name"; then
      printf '\n--- %s ---\n' "$name"
      service_action status "$name"
    fi
  done
}

control_services() {
  local action choice names=() name
  printf '1) start\n2) stop\n3) restart\n'
  choice=$(prompt "操作" "3")
  case "$choice" in 1) action=start ;; 2) action=stop ;; 3) action=restart ;; *) die "无效选项。" ;; esac
  printf '1) Snell v5\n2) ShadowTLS\n3) Snell v6\n4) 全部\n'
  choice=$(prompt "目标" "4")
  case "$choice" in 1) names=(snell-v5) ;; 2) names=(shadowtls-snell-v5) ;; 3) names=(snell-v6) ;; 4) names=(snell-v5 shadowtls-snell-v5 snell-v6) ;; *) die "无效选项。" ;; esac
  for name in "${names[@]}"; do service_exists "$name" && service_action "$action" "$name"; done
}

update_binaries() {
  install_dependencies
  [[ -f "${CONFIG_DIR}/snell-v5.conf" ]] && download_surge 5
  [[ -f "${CONFIG_DIR}/snell-v6.conf" ]] && download_surge 6
  [[ $(get_meta v5_shadowtls) == "yes" ]] && download_shadowtls
  service_exists snell-v5 && service_action restart snell-v5
  service_exists snell-v6 && service_action restart snell-v6
  service_exists shadowtls-snell-v5 && service_action restart shadowtls-snell-v5
  ok "已更新并重启现有实例。"
}

remove_service() {
  local name=$1
  stop_if_exists "$name"
  service_action disable "$name" 2>/dev/null || true
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then rm -f "/etc/systemd/system/${name}.service"; else rm -f "/etc/init.d/${name}"; fi
}

uninstall_all() {
  warn "将删除 Snell v5/v6、ShadowTLS 的服务、二进制和配置。"
  yes_no "确定卸载？" n || return 0
  remove_service shadowtls-snell-v5
  remove_service snell-v5
  remove_service snell-v6
  reload_init
  rm -rf "$CONFIG_DIR" "$BIN_DIR" "$LOG_DIR"
  ok "卸载完成。"
}

main_menu() {
  while true; do
    header "Snell v5/v6 共存管理器（Debian / Alpine）"
    printf '1) 安装/重装 Snell v5（可套 ShadowTLS）\n'
    printf '2) 安装/重装 Snell v6\n'
    printf '3) 同时安装 v5 + v6\n'
    printf '4) 为现有 v5 配置 ShadowTLS\n'
    printf '5) 显示客户端参数\n'
    printf '6) 查看服务状态\n'
    printf '7) 启动/停止/重启服务\n'
    printf '8) 更新已安装的二进制\n'
    printf '9) 卸载全部\n'
    printf '0) 退出\n\n'
    case "$(prompt '请选择' '3')" in
      1) install_v5 ;; 2) install_v6 ;; 3) install_both ;; 4) install_dependencies; configure_shadowtls; service_action restart shadowtls-snell-v5; show_info ;;
      5) show_info ;; 6) status_all ;; 7) control_services ;; 8) update_binaries ;; 9) uninstall_all ;; 0) exit 0 ;; *) warn "无效选项。" ;;
    esac
    printf '\n'; read -r -p '按 Enter 返回主菜单...' _ </dev/tty
  done
}

usage() {
  cat <<EOF
用法: $0 [menu|install|install-v5|install-v6|info|status|update|uninstall]

无参数时进入交互菜单。install 表示交互式同时安装 v5 和 v6。
可通过环境变量 SNELL_V5_VERSION / SNELL_V6_VERSION 临时覆盖下载版本。
Snell v6 默认安装当前 v6.0.0rc2；请确保 Surge 客户端也已更新到兼容版本。
EOF
}

main() {
  require_root
  detect_platform
  case "${1:-menu}" in
    menu) main_menu ;; install) install_both ;; install-v5) install_v5 ;; install-v6) install_v6 ;;
    info) show_info ;; status) status_all ;; update) update_binaries ;; uninstall) uninstall_all ;;
    -h|--help|help) usage ;; *) usage; exit 1 ;;
  esac
}

main "$@"
