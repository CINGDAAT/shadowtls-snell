#!/usr/bin/env bash
set -Eeuo pipefail

# ShadowTLS + Snell v5 manager
# Target: Linux + systemd
# ShadowTLS upstream: https://github.com/ihciah/shadow-tls

VERSION="1.0.0"

STLS_BIN="/usr/local/bin/shadow-tls"
STLS_SERVICE="/etc/systemd/system/shadow-tls.service"
STATE_DIR="/etc/shadowtls-snell"
STATE_FILE="${STATE_DIR}/config.env"
MANAGER_BIN="/usr/local/lib/shadowtls-snell-manager.sh"
SHORTCUT="/usr/local/bin/shadowtls"
DEFAULT_SNELL_CONFIG="/etc/snell/snell-server.conf"
DEFAULT_SNELL_SERVICE="snell-server.service"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

info() { echo -e "${CYAN}[i]${RESET} $*"; }
ok() { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
die() { echo -e "${RED}[x]${RESET} $*" >&2; exit 1; }

pause() {
  echo
  read -r -p "按回车返回菜单..." _ || true
}

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 权限运行此脚本。"
}

need_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "此脚本需要 systemd。"
}

install_deps() {
  local missing=0
  for c in curl openssl ss awk sed grep; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  [[ $missing -eq 0 ]] && return 0

  info "安装必要依赖..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates openssl iproute2 gawk sed grep
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl iproute gawk sed grep
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl iproute gawk sed grep
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates openssl iproute2 gawk sed grep
  else
    die "无法识别包管理器，请手动安装 curl openssl iproute2 awk sed grep。"
  fi
}

install_shortcut() {
  mkdir -p "$(dirname "$MANAGER_BIN")"

  local src="${BASH_SOURCE[0]:-$0}"
  if [[ -r "$src" ]]; then
    local src_real dst_real
    src_real="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    dst_real="$(readlink -f "$MANAGER_BIN" 2>/dev/null || echo "$MANAGER_BIN")"
    if [[ "$src_real" != "$dst_real" ]]; then
      cp -f "$src" "$MANAGER_BIN"
      chmod 0755 "$MANAGER_BIN"
    fi
  elif [[ ! -f "$MANAGER_BIN" ]]; then
    warn "无法复制当前脚本到 $MANAGER_BIN；本次仍可运行，但不会创建永久快捷入口。"
    return 0
  fi

  cat > "$SHORTCUT" <<EOF2
#!/usr/bin/env bash
exec bash "$MANAGER_BIN" "\$@"
EOF2
  chmod 0755 "$SHORTCUT"
}

arch_asset() {
  case "$(uname -m)" in
    x86_64|amd64) echo "shadow-tls-x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "shadow-tls-aarch64-unknown-linux-musl" ;;
    armv7l|armv7) echo "shadow-tls-armv7-unknown-linux-musleabihf" ;;
    armv6l|armv6) echo "shadow-tls-arm-unknown-linux-musleabi" ;;
    *) die "暂不支持架构: $(uname -m)" ;;
  esac
}

latest_shadowtls_tag() {
  local tag
  tag="$(curl -fsSL --connect-timeout 8 --max-time 15 \
    https://api.github.com/repos/ihciah/shadow-tls/releases/latest 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1 || true)"
  [[ -n "$tag" ]] || tag="v0.2.25"
  echo "$tag"
}

download_shadowtls() {
  local tag asset url tmp
  tag="$(latest_shadowtls_tag)"
  asset="$(arch_asset)"
  url="https://github.com/ihciah/shadow-tls/releases/download/${tag}/${asset}"
  tmp="$(mktemp)"

  info "下载 ShadowTLS ${tag} (${asset})..."
  if ! curl -fL --retry 3 --connect-timeout 10 -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "ShadowTLS 下载失败: $url"
  fi

  chmod 0755 "$tmp"
  "$tmp" --help >/dev/null 2>&1 || {
    rm -f "$tmp"
    die "下载到的 ShadowTLS 二进制无法执行。"
  }

  install -m 0755 "$tmp" "$STLS_BIN"
  rm -f "$tmp"
  ok "ShadowTLS ${tag} 已安装。"
}

find_snell_config() {
  local cfg=""

  if systemctl cat "$DEFAULT_SNELL_SERVICE" >/dev/null 2>&1; then
    cfg="$(systemctl cat "$DEFAULT_SNELL_SERVICE" 2>/dev/null \
      | sed -nE 's#^ExecStart=.*[[:space:]]-c[[:space:]]+([^[:space:]]+).*#\1#p' \
      | head -n1 || true)"
  fi

  if [[ -n "$cfg" && -f "$cfg" ]]; then
    echo "$cfg"
    return 0
  fi

  if [[ -f "$DEFAULT_SNELL_CONFIG" ]]; then
    echo "$DEFAULT_SNELL_CONFIG"
    return 0
  fi

  for cfg in /etc/snell/*.conf /usr/local/etc/snell/*.conf; do
    [[ -f "$cfg" ]] || continue
    if grep -Eq '^[[:space:]]*\[snell-server\]' "$cfg"; then
      echo "$cfg"
      return 0
    fi
  done

  return 1
}

find_snell_service() {
  if systemctl cat "$DEFAULT_SNELL_SERVICE" >/dev/null 2>&1; then
    echo "$DEFAULT_SNELL_SERVICE"
    return 0
  fi

  local svc
  svc="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '$1 ~ /^snell.*\.service$/ {print $1; exit}' || true)"
  [[ -n "$svc" ]] || svc="$DEFAULT_SNELL_SERVICE"
  echo "$svc"
}

cfg_value() {
  local key="$1" file="$2"
  awk -v k="$key" '
    BEGIN { IGNORECASE=1 }
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      line=$0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$file"
}

snell_port_from_listen() {
  local listen="$1"
  echo "$listen" | sed -nE 's#.*:([0-9]{1,5})[[:space:]]*$#\1#p'
}

validate_snell_v5ish() {
  local file="$1"
  if grep -Eq '^[[:space:]]*(dns-ip-preference|mode)[[:space:]]*=' "$file"; then
    die "检测到疑似 Snell v6 配置。本脚本只用于 Snell v4/v5（重点适配 v5）。"
  fi

  grep -Eq '^[[:space:]]*listen[[:space:]]*=' "$file" || die "Snell 配置缺少 listen。"
  grep -Eq '^[[:space:]]*psk[[:space:]]*=' "$file" || die "Snell 配置缺少 psk。"
}

save_state() {
  mkdir -p "$STATE_DIR"
  umask 077
  {
    printf 'SNELL_CONFIG=%q\n' "$SNELL_CONFIG"
    printf 'SNELL_SERVICE=%q\n' "$SNELL_SERVICE"
    printf 'SNELL_PORT=%q\n' "$SNELL_PORT"
    printf 'ORIGINAL_SNELL_LISTEN=%q\n' "$ORIGINAL_SNELL_LISTEN"
    printf 'ORIGINAL_SNELL_OBFS=%q\n' "$ORIGINAL_SNELL_OBFS"
    printf 'STLS_PORT=%q\n' "$STLS_PORT"
    printf 'STLS_PASSWORD=%q\n' "$STLS_PASSWORD"
    printf 'STLS_SNI=%q\n' "$STLS_SNI"
    printf 'LEGACY_DRIVER=%q\n' "${LEGACY_DRIVER:-false}"
  } > "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  return 0
}

set_config_key() {
  local file="$1" key="$2" value="$3"
  if grep -Eqi "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -i -E "s#^[[:space:]]*${key}[[:space:]]*=.*#${key} = ${value}#I" "$file"
  else
    printf '\n%s = %s\n' "$key" "$value" >> "$file"
  fi
}

remove_config_key() {
  local file="$1" key="$2"
  sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/Id" "$file"
}

prepare_snell_backend() {
  [[ -f "$SNELL_CONFIG" ]] || die "Snell 配置文件不存在: $SNELL_CONFIG"
  validate_snell_v5ish "$SNELL_CONFIG"

  set_config_key "$SNELL_CONFIG" "listen" "127.0.0.1:${SNELL_PORT}"

  # ShadowTLS 本身已经是外层伪装；避免 Snell 自带 obfs 与客户端配置不一致。
  if grep -Eqi '^[[:space:]]*obfs[[:space:]]*=' "$SNELL_CONFIG"; then
    set_config_key "$SNELL_CONFIG" "obfs" "off"
  fi

  systemctl restart "$SNELL_SERVICE" || {
    systemctl status "$SNELL_SERVICE" --no-pager -l || true
    die "Snell 重启失败，请检查配置。"
  }

  sleep 1
  systemctl is-active --quiet "$SNELL_SERVICE" || die "Snell 服务未处于运行状态。"
  ok "Snell 已改为本机后端 127.0.0.1:${SNELL_PORT}。"
}

restore_snell_backend() {
  [[ -n "${SNELL_CONFIG:-}" && -f "$SNELL_CONFIG" ]] || return 0

  set_config_key "$SNELL_CONFIG" "listen" "$ORIGINAL_SNELL_LISTEN"

  if [[ "${ORIGINAL_SNELL_OBFS:-__ABSENT__}" == "__ABSENT__" ]]; then
    remove_config_key "$SNELL_CONFIG" "obfs"
  else
    set_config_key "$SNELL_CONFIG" "obfs" "$ORIGINAL_SNELL_OBFS"
  fi

  systemctl restart "$SNELL_SERVICE" >/dev/null 2>&1 || true
  ok "已恢复 Snell 原监听配置: $ORIGINAL_SNELL_LISTEN"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

port_busy() {
  local p="$1"
  ss -ltnH 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {found=1} END {exit !found}'
}

prompt_port() {
  local default="$1" p
  while true; do
    read -r -p "ShadowTLS 公网 TCP 端口 [${default}]: " p
    p="${p:-$default}"
    valid_port "$p" || { warn "端口必须为 1-65535。"; continue; }
    [[ "$p" != "$SNELL_PORT" ]] || { warn "公网端口不能与 Snell 后端端口相同。" >&2; continue; }
    if port_busy "$p"; then
      warn "TCP 端口 $p 已被占用，请换一个。" >&2
      continue
    fi
    echo "$p"
    return 0
  done
}

valid_domain_syntax() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$1" == *.* ]]
}

check_tls13() {
  local domain="$1"
  info "检测 ${domain}:443 的 TLS 1.3..." >&2
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 openssl s_client -connect "${domain}:443" -servername "$domain" -tls1_3 </dev/null 2>&1 | grep -q 'TLSv1.3'
  else
    openssl s_client -connect "${domain}:443" -servername "$domain" -tls1_3 </dev/null 2>&1 | grep -q 'TLSv1.3'
  fi
}

prompt_sni() {
  local default="$1" d reply
  while true; do
    read -r -p "ShadowTLS 伪装域名/SNI [${default}]: " d
    d="${d:-$default}"
    valid_domain_syntax "$d" || { warn "域名格式看起来不正确。" >&2; continue; }
    if check_tls13 "$d"; then
      ok "$d 支持 TLS 1.3。" >&2
      echo "$d"
      return 0
    fi
    warn "未能确认 $d 支持 TLS 1.3；可能是目标限制探测或网络问题。" >&2
    read -r -p "仍然使用该域名？[y/N]: " reply
    if [[ "${reply,,}" == "y" ]]; then
      echo "$d"
      return 0
    fi
  done
}

generate_password() {
  openssl rand -hex 16
}

write_service() {
  local legacy_line=""
  [[ "${LEGACY_DRIVER:-false}" == "true" ]] && legacy_line="Environment=MONOIO_FORCE_LEGACY_DRIVER=1"

  cat > "$STLS_SERVICE" <<EOF2
[Unit]
Description=ShadowTLS v3 for Snell
After=network-online.target ${SNELL_SERVICE}
Wants=network-online.target
Requires=${SNELL_SERVICE}

[Service]
Type=simple
User=root
LimitNOFILE=65536
${legacy_line}
ExecStart=${STLS_BIN} --v3 --strict server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${SNELL_PORT} --tls ${STLS_SNI}:443 --password ${STLS_PASSWORD}
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
}

open_firewall() {
  local p="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${p}/tcp" comment 'ShadowTLS' >/dev/null 2>&1 || true
    ok "已尝试放行 UFW TCP/${p}。"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "已尝试放行 firewalld TCP/${p}。"
  fi
}

start_shadowtls() {
  write_service
  systemctl enable --now shadow-tls.service
  sleep 1
  if ! systemctl is-active --quiet shadow-tls.service; then
    systemctl status shadow-tls.service --no-pager -l || true
    journalctl -u shadow-tls.service -n 30 --no-pager || true
    die "ShadowTLS 启动失败。"
  fi
  ok "ShadowTLS 已启动。"
}

public_ipv4() {
  local ip=""
  ip="$(curl -4fsS --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "${ip:-YOUR_SERVER_IP}"
}

show_info() {
  load_state || { warn "尚未配置 ShadowTLS + Snell。"; return 1; }

  local ip psk status stls_ver
  ip="$(public_ipv4)"
  psk="$(cfg_value psk "$SNELL_CONFIG" 2>/dev/null || true)"
  status="$(systemctl is-active shadow-tls.service 2>/dev/null || true)"
  stls_ver="$($STLS_BIN --version 2>/dev/null | head -n1 || true)"
  [[ -n "$stls_ver" ]] || stls_ver="已安装"

  echo
  echo -e "${BOLD}================ ShadowTLS + Snell =================${RESET}"
  printf "ShadowTLS 状态 : %s\n" "$status"
  printf "ShadowTLS 版本 : %s\n" "$stls_ver"
  printf "公网地址        : %s:%s/TCP\n" "$ip" "$STLS_PORT"
  printf "Snell 后端      : 127.0.0.1:%s\n" "$SNELL_PORT"
  printf "伪装 SNI        : %s\n" "$STLS_SNI"
  printf "ShadowTLS 密码  : %s\n" "$STLS_PASSWORD"
  printf "Snell PSK       : %s\n" "$psk"
  printf "Snell 配置      : %s\n" "$SNELL_CONFIG"
  echo
  echo -e "${BOLD}Surge 配置（Snell v5 + ShadowTLS v3）${RESET}"
  echo "Snell-sTLS = snell, ${ip}, ${STLS_PORT}, psk=\"${psk}\", version=5, reuse=true, block-quic=on, shadow-tls-password=\"${STLS_PASSWORD}\", shadow-tls-version=3, shadow-tls-sni=${STLS_SNI}"
  echo
  echo -e "${YELLOW}说明：block-quic=on 用于避免 Snell v5 QUIC Proxy Mode 走公网 UDP；普通 UDP 仍可通过 Snell 的 UDP-over-TCP。${RESET}"
}

first_install() {
  install_deps

  if load_state; then
    warn "检测到已有配置，将进入重新配置。"
    reconfigure
    return 0
  fi

  SNELL_CONFIG="$(find_snell_config || true)"
  [[ -n "$SNELL_CONFIG" ]] || die "没有找到 Snell 配置。请先安装 Snell v5，例如 bash <(curl -fsSL https://s.ee/opensnell)"
  SNELL_SERVICE="$(find_snell_service)"

  validate_snell_v5ish "$SNELL_CONFIG"

  ORIGINAL_SNELL_LISTEN="$(cfg_value listen "$SNELL_CONFIG")"
  [[ -n "$ORIGINAL_SNELL_LISTEN" ]] || die "无法读取 Snell listen。"
  SNELL_PORT="$(snell_port_from_listen "$ORIGINAL_SNELL_LISTEN")"
  valid_port "$SNELL_PORT" || die "无法从 Snell listen 解析端口: $ORIGINAL_SNELL_LISTEN"

  if grep -Eqi '^[[:space:]]*obfs[[:space:]]*=' "$SNELL_CONFIG"; then
    ORIGINAL_SNELL_OBFS="$(cfg_value obfs "$SNELL_CONFIG")"
  else
    ORIGINAL_SNELL_OBFS="__ABSENT__"
  fi

  local psk
  psk="$(cfg_value psk "$SNELL_CONFIG")"
  [[ -n "$psk" ]] || die "无法读取 Snell PSK。"

  echo
  info "检测到 Snell: $SNELL_CONFIG"
  info "Snell 后端端口: $SNELL_PORT"
  info "Snell 服务: $SNELL_SERVICE"

  download_shadowtls

  # 先把 Snell 收到 localhost，释放原公网绑定。
  prepare_snell_backend

  STLS_PORT="$(prompt_port 443)"
  STLS_SNI="$(prompt_sni www.cloudflare.com)"
  STLS_PASSWORD="$(generate_password)"
  LEGACY_DRIVER="false"

  save_state
  open_firewall "$STLS_PORT"
  start_shadowtls
  show_info
}

reconfigure() {
  load_state || { first_install; return 0; }
  install_deps

  systemctl stop shadow-tls.service >/dev/null 2>&1 || true

  local new_port new_sni new_password reply
  new_port="$(prompt_port "$STLS_PORT")"
  new_sni="$(prompt_sni "$STLS_SNI")"
  read -r -p "重新生成 ShadowTLS 密码？[y/N]: " reply
  if [[ "${reply,,}" == "y" ]]; then
    new_password="$(generate_password)"
  else
    new_password="$STLS_PASSWORD"
  fi

  STLS_PORT="$new_port"
  STLS_SNI="$new_sni"
  STLS_PASSWORD="$new_password"

  prepare_snell_backend
  save_state
  open_firewall "$STLS_PORT"
  start_shadowtls
  show_info
}

change_port() {
  load_state || { warn "请先安装配置。"; return 1; }
  systemctl stop shadow-tls.service >/dev/null 2>&1 || true
  STLS_PORT="$(prompt_port "$STLS_PORT")"
  save_state
  open_firewall "$STLS_PORT"
  start_shadowtls
  show_info
}

change_password() {
  load_state || { warn "请先安装配置。"; return 1; }
  local p reply
  read -r -p "输入新密码（留空自动生成）: " p
  p="${p:-$(generate_password)}"
  [[ "$p" != *[[:space:]]* ]] || { warn "密码不能包含空白字符。"; return 1; }
  STLS_PASSWORD="$p"
  save_state
  systemctl restart shadow-tls.service
  show_info
}

change_sni() {
  load_state || { warn "请先安装配置。"; return 1; }
  STLS_SNI="$(prompt_sni "$STLS_SNI")"
  save_state
  write_service
  systemctl restart shadow-tls.service
  show_info
}

update_shadowtls() {
  load_state || { warn "请先安装配置。"; return 1; }
  install_deps
  download_shadowtls
  systemctl restart shadow-tls.service
  ok "ShadowTLS 已更新并重启。"
  show_info
}

toggle_legacy() {
  load_state || { warn "请先安装配置。"; return 1; }
  if [[ "${LEGACY_DRIVER:-false}" == "true" ]]; then
    LEGACY_DRIVER="false"
    ok "已切换为默认 io_uring/系统驱动模式。"
  else
    LEGACY_DRIVER="true"
    ok "已启用 MONOIO_FORCE_LEGACY_DRIVER=1（epoll 兼容模式）。"
  fi
  save_state
  write_service
  systemctl restart shadow-tls.service
}

uninstall_all() {
  local reply restore_reply
  read -r -p "确认卸载 ShadowTLS 管理器和服务？[y/N]: " reply
  [[ "${reply,,}" == "y" ]] || return 0

  if load_state; then
    read -r -p "恢复 Snell 原来的公网监听 ${ORIGINAL_SNELL_LISTEN}？[Y/n]: " restore_reply
    restore_reply="${restore_reply:-y}"
  else
    restore_reply="n"
  fi

  systemctl disable --now shadow-tls.service >/dev/null 2>&1 || true
  rm -f "$STLS_SERVICE"
  systemctl daemon-reload

  if [[ "${restore_reply,,}" == "y" ]]; then
    restore_snell_backend
  fi

  rm -f "$STLS_BIN"
  rm -rf "$STATE_DIR"
  rm -f "$SHORTCUT"
  rm -f "$MANAGER_BIN"

  ok "ShadowTLS 管理器已卸载。"
  warn "脚本不会自动删除之前添加的防火墙放行规则；如需收紧规则，请自行检查 UFW/firewalld。"
}

show_status_header() {
  local stls_status="未安装" snell_status="未知"
  if systemctl is-active --quiet shadow-tls.service 2>/dev/null; then
    stls_status="运行中"
  elif [[ -f "$STLS_SERVICE" ]]; then
    stls_status="已安装/未运行"
  fi

  if load_state >/dev/null 2>&1; then
    if systemctl is-active --quiet "$SNELL_SERVICE" 2>/dev/null; then
      snell_status="运行中"
    else
      snell_status="未运行"
    fi
  elif systemctl is-active --quiet "$DEFAULT_SNELL_SERVICE" 2>/dev/null; then
    snell_status="运行中"
  fi

  clear 2>/dev/null || true
  echo -e "${BOLD}=================================================${RESET}"
  echo -e "${BOLD}       ShadowTLS + Snell v5 管理器 v${VERSION}${RESET}"
  echo -e "${BOLD}=================================================${RESET}"
  echo -e "ShadowTLS: ${CYAN}${stls_status}${RESET}    Snell: ${CYAN}${snell_status}${RESET}"
  echo
}

menu() {
  while true; do
    show_status_header
    cat <<'EOF2'
1. 安装 / 自动套 Snell v5
2. 查看配置与 Surge 节点
3. 重新配置 ShadowTLS
4. 修改公网端口
5. 修改 ShadowTLS 密码
6. 修改伪装域名 SNI
7. 重启 ShadowTLS + Snell
8. 查看 ShadowTLS 日志
9. 更新 ShadowTLS
10. 切换 epoll 兼容模式
11. 卸载 ShadowTLS（可恢复 Snell 原监听）
0. 退出
EOF2
    echo
    read -r -p "请选择 [0-11]: " choice
    case "$choice" in
      1) first_install; pause ;;
      2) show_info || true; pause ;;
      3) reconfigure; pause ;;
      4) change_port || true; pause ;;
      5) change_password || true; pause ;;
      6) change_sni || true; pause ;;
      7)
        if load_state; then
          systemctl restart "$SNELL_SERVICE" shadow-tls.service
          ok "Snell 与 ShadowTLS 已重启。"
        else
          warn "尚未安装配置。"
        fi
        pause
        ;;
      8) journalctl -u shadow-tls.service -n 100 --no-pager; pause ;;
      9) update_shadowtls || true; pause ;;
      10) toggle_legacy || true; pause ;;
      11) uninstall_all; exit 0 ;;
      0) exit 0 ;;
      *) warn "无效选项。"; sleep 1 ;;
    esac
  done
}

main() {
  need_root
  need_systemd
  install_shortcut

  case "${1:-menu}" in
    menu) menu ;;
    install) first_install ;;
    info) show_info ;;
    reconfigure) reconfigure ;;
    update) update_shadowtls ;;
    restart)
      load_state || die "尚未配置。"
      systemctl restart "$SNELL_SERVICE" shadow-tls.service
      ;;
    status) systemctl status shadow-tls.service --no-pager -l ;;
    logs) journalctl -u shadow-tls.service -n 100 --no-pager ;;
    uninstall) uninstall_all ;;
    *)
      echo "用法: shadowtls [menu|install|info|reconfigure|update|restart|status|logs|uninstall]"
      exit 1
      ;;
  esac
}

main "$@"
