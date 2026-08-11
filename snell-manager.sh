#!/bin/sh
set -eu

# Snell v5/v6 manager for Alpine Linux
# POSIX /bin/sh compatible (BusyBox ash).
#
# Usage:
#   ./snell-manager.sh                # interactive menu
#   ./snell-manager.sh install [5|6]
#   ./snell-manager.sh update
#   ./snell-manager.sh show
#   ./snell-manager.sh port 6160
#   ./snell-manager.sh psk [NEW_PSK]
#   ./snell-manager.sh mode default|unshaped|unsafe-raw
#   ./snell-manager.sh dns default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only
#   ./snell-manager.sh host <server_ip_or_domain>
#   ./snell-manager.sh local-dns show
#   ./snell-manager.sh local-dns set 1.1.1.1 8.8.8.8
#   ./snell-manager.sh local-dns restore
#   ./snell-manager.sh ipv6 on|off
#   ./snell-manager.sh tfo on|off
#   ./snell-manager.sh shadowtls enable|disable|update|show
#   ./snell-manager.sh restart|start|stop|status
#   ./snell-manager.sh logs
#   ./snell-manager.sh uninstall [--yes]
#
# Optional environment variables for install:
#   PORT=6160
#   PSK=your_psk
#   MODE=default|unshaped|unsafe-raw
#   DNS_PREFERENCE=default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only
#   ENABLE_IPV6=0|1
#   SERVER_HOST=1.2.3.4_or_domain
#   CLIENT_TFO=0|1
#   SHADOWTLS_ENABLE=0|1            # Snell v5 only
#   SHADOWTLS_PORT=8443             # public TCP port
#   SHADOWTLS_SNI=www.icloud.com
#   SHADOWTLS_PASSWORD=...
#   SHADOWTLS_URL=https://github.com/ihciah/shadow-tls/releases/download/...
#   LOCAL_DNS="1.1.1.1 8.8.8.8"
#   SNELL_VERSION=5|6
#   SNELL_URL=https://.../snell-server-v5-or-v6...-linux-amd64.zip
#   ALLOW_UNSAFE_RAW=1

CONF_DIR="/etc/snell"
CONF_FILE="${CONF_DIR}/snell-server.conf"
BIN_FILE="/usr/local/bin/snell-server"
INIT_FILE="/etc/init.d/snell"
LOG_FILE="/var/log/snell.log"
STATE_FILE="${CONF_DIR}/manager.conf"
DNS_BACKUP_FILE="${CONF_DIR}/resolv.conf.backup"
RESOLV_CONF="/etc/resolv.conf"
UDHCPC_CONF="/etc/udhcpc/udhcpc.conf"
UDHCPC_BACKUP_FILE="${CONF_DIR}/udhcpc.conf.backup"
SERVICE_NAME="snell"
RELEASE_PAGE="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
SHADOWTLS_BIN="/usr/local/bin/shadow-tls"
SHADOWTLS_INIT="/etc/init.d/shadowtls-snell"
SHADOWTLS_LOG="/var/log/shadowtls-snell.log"
SHADOWTLS_SERVICE="shadowtls-snell"
SHADOWTLS_RELEASE_API="https://api.github.com/repos/ihciah/shadow-tls/releases/latest"
SHADOWTLS_LATEST_PAGE="https://github.com/ihciah/shadow-tls/releases/latest"
SHADOWTLS_FALLBACK_VERSION="v0.2.25"
DEFAULT_SHADOWTLS_SNI="www.icloud.com"

log() { printf '%s\n' "[snell] $*"; }
warn() { printf '%s\n' "[snell] WARNING: $*" >&2; }
die() { printf '%s\n' "[snell] ERROR: $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root."
}

check_platform() {
  [ -f /etc/alpine-release ] || die "This script only supports Alpine Linux."
  command -v apk >/dev/null 2>&1 || die "apk was not found; this does not look like a usable Alpine Linux system."

  ALPINE_VERSION="$(cat /etc/alpine-release 2>/dev/null || true)"
  [ -n "$ALPINE_VERSION" ] || ALPINE_VERSION="unknown"

  # Deliberately do not whitelist Alpine release numbers. Future and older
  # releases are accepted and actual compatibility is checked at runtime.
  case "$(uname -m)" in
    x86_64) SNELL_ARCH="amd64" ;;
    aarch64|arm64) SNELL_ARCH="aarch64" ;;
    armv7l|armv7) SNELL_ARCH="armv7l" ;;
    i386|i486|i586|i686) SNELL_ARCH="i386" ;;
    *) die "Unsupported CPU architecture: $(uname -m). No matching official Snell Linux package is known." ;;
  esac
}

ensure_dependencies() {
  log "Installing/checking dependencies on Alpine ${ALPINE_VERSION}..."
  apk update || die "apk update failed. Check /etc/apk/repositories and network connectivity."

  # Keep the base dependency set conservative so this also works on older
  # Alpine branches. OpenRC is installed explicitly for minimal VPS images.
  apk add --no-cache ca-certificates curl unzip openssl iproute2 openrc     || die "Unable to install required Alpine packages."

  # Snell's Linux binary expects glibc-compatible APIs. Prefer gcompat on
  # modern Alpine. Older branches may only have libc6-compat in enabled repos.
  if apk add --no-cache gcompat >/dev/null 2>&1; then
    GLIBC_COMPAT="gcompat"
  elif apk add --no-cache libc6-compat >/dev/null 2>&1; then
    GLIBC_COMPAT="libc6-compat"
    warn "gcompat is unavailable; using libc6-compat as a best-effort fallback."
  else
    die "Neither gcompat nor libc6-compat could be installed. Enable the appropriate Alpine repositories or use a newer Alpine release."
  fi

  update-ca-certificates >/dev/null 2>&1 || true
}

trim_value() {
  # Usage: trim_value "text"
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

state_get() {
  key="$1"
  [ -f "$STATE_FILE" ] || return 1
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE"
}

state_set() {
  key="$1"
  value="$2"
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  umask 077
  tmp="${STATE_FILE}.tmp.$$"
  if [ -f "$STATE_FILE" ]; then
    awk -F= -v key="$key" '$1 != key {print}' "$STATE_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

validate_snell_major() {
  case "$1" in
    5|6) return 0 ;;
    *) return 1 ;;
  esac
}

installed_major_from_version() {
  ver="$(installed_version 2>/dev/null || true)"
  case "$ver" in
    v5*) printf '5\n' ;;
    v6*) printf '6\n' ;;
    *) return 1 ;;
  esac
}

current_snell_major() {
  major="$(installed_major_from_version 2>/dev/null || true)"
  if validate_snell_major "$major"; then
    printf '%s\n' "$major"
    return 0
  fi

  major="$(state_get SNELL_MAJOR 2>/dev/null || true)"
  if validate_snell_major "$major"; then
    printf '%s\n' "$major"
    return 0
  fi

  if [ -f "$CONF_FILE" ]; then
    if grep -Eq '^[[:space:]]*(dns-ip-preference|mode)[[:space:]]*=' "$CONF_FILE"; then
      printf '6\n'
      return 0
    fi
    if grep -Eq '^[[:space:]]*ipv6[[:space:]]*=' "$CONF_FILE"; then
      printf '5\n'
      return 0
    fi
  fi
  return 1
}

select_snell_major_on_install() {
  requested="${SNELL_VERSION:-}"
  current="$(current_snell_major 2>/dev/null || true)"
  default_major="${current:-6}"

  if [ -n "$requested" ]; then
    validate_snell_major "$requested" || die "SNELL_VERSION must be 5 or 6."
    TARGET_MAJOR="$requested"
  elif [ -t 0 ]; then
    while :; do
      printf 'Snell version to install [5/6] [%s]: ' "$default_major"
      read -r requested || die "Unable to read Snell version."
      requested="$(trim_value "$requested")"
      [ -n "$requested" ] || requested="$default_major"
      if validate_snell_major "$requested"; then
        TARGET_MAJOR="$requested"
        break
      fi
      warn "Enter 5 or 6."
    done
  else
    TARGET_MAJOR="$default_major"
  fi

  if [ "$TARGET_MAJOR" = "6" ] && [ "$SNELL_ARCH" = "armv7l" ]; then
    die "Official Snell v6 does not currently provide an armv7l Linux package. Use Snell v5 on this CPU."
  fi
  export TARGET_MAJOR
  log "Selected Snell v${TARGET_MAJOR}."
}

normalize_server_host() {
  host="$(trim_value "$1")"
  case "$host" in
    \[*\]) host="${host#\[}"; host="${host%\]}" ;;
  esac
  printf '%s\n' "$host"
}

validate_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 {ok=0; exit}
    BEGIN {ok=1}
    {
      for (i=1; i<=4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {ok=0; exit}
      }
    }
    END {exit ok ? 0 : 1}
  ' >/dev/null 2>&1
}

validate_server_host() {
  host="$(normalize_server_host "$1")"
  [ -n "$host" ] || return 1
  case "$host" in
    *[!A-Za-z0-9._:-]*|*..*|.*|*.) return 1 ;;
  esac
  case "$host" in
    *:*)
      case "$host" in *[!0-9A-Fa-f:.]*) return 1 ;; esac
      ;;
    *.*)
      case "$host" in
        *[!0-9.]*) : ;;
        *) validate_ipv4 "$host" || return 1 ;;
      esac
      ;;
  esac
  return 0
}

current_server_host() {
  if [ -n "${SERVER_HOST:-}" ]; then
    normalize_server_host "$SERVER_HOST"
  else
    state_get SERVER_HOST 2>/dev/null || true
  fi
}

set_server_host() {
  host="$(normalize_server_host "$1")"
  validate_server_host "$host" || die "Invalid server IP/domain: ${1}"
  state_set SERVER_HOST "$host"
  SERVER_HOST="$host"
  export SERVER_HOST
  log "Server address saved as ${host}."
}

ensure_server_host() {
  host="$(current_server_host)"
  if [ -n "$host" ]; then
    validate_server_host "$host" || die "Saved SERVER_HOST is invalid: ${host}"
    state_set SERVER_HOST "$host"
    return 0
  fi
  if [ -t 0 ]; then
    while :; do
      printf 'Server IP or domain (used by clients to connect): '
      read -r host || die "Unable to read server address."
      if validate_server_host "$host"; then
        set_server_host "$host"
        return 0
      fi
      warn "Enter a valid IPv4, IPv6, or domain name without scheme or port."
    done
  fi
  warn "SERVER_HOST is not set. Surge output will use YOUR_SERVER_IP until you run: $0 host <IP-or-domain>"
}

format_client_host() {
  host="$1"
  case "$host" in
    *:*) printf '[%s]\n' "$host" ;;
    *) printf '%s\n' "$host" ;;
  esac
}

validate_dns_server() {
  dns="$1"
  [ -n "$dns" ] || return 1
  case "$dns" in
    *:*)
      case "$dns" in *[!0-9A-Fa-f:.]*) return 1 ;; esac
      return 0
      ;;
    *) validate_ipv4 "$dns" ;;
  esac
}

backup_system_dns() {
  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  if [ ! -f "$DNS_BACKUP_FILE" ]; then
    if [ -e "$RESOLV_CONF" ]; then
      cp -L "$RESOLV_CONF" "$DNS_BACKUP_FILE"
    else
      : > "$DNS_BACKUP_FILE"
    fi
    chmod 600 "$DNS_BACKUP_FILE"
    log "Backed up current DNS to ${DNS_BACKUP_FILE}."
  fi

  if [ -z "$(state_get UDHCPC_CONF_EXISTED 2>/dev/null || true)" ]; then
    if [ -f "$UDHCPC_CONF" ]; then
      cp "$UDHCPC_CONF" "$UDHCPC_BACKUP_FILE"
      chmod 600 "$UDHCPC_BACKUP_FILE"
      state_set UDHCPC_CONF_EXISTED 1
    else
      state_set UDHCPC_CONF_EXISTED 0
    fi
  fi
}

disable_dhcp_dns_overwrite() {
  mkdir -p "$(dirname "$UDHCPC_CONF")"
  tmp="${CONF_DIR}/udhcpc.conf.new.$$"
  if [ -f "$UDHCPC_CONF" ]; then
    awk '!/^[[:space:]]*RESOLV_CONF[[:space:]]*=/' "$UDHCPC_CONF" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\n' 'RESOLV_CONF="no"' >> "$tmp"
  cat "$tmp" > "$UDHCPC_CONF"
  chmod 644 "$UDHCPC_CONF"
  rm -f "$tmp"
}

restore_udhcpc_dns_behavior() {
  existed="$(state_get UDHCPC_CONF_EXISTED 2>/dev/null || true)"
  case "$existed" in
    1)
      if [ -f "$UDHCPC_BACKUP_FILE" ]; then
        cat "$UDHCPC_BACKUP_FILE" > "$UDHCPC_CONF"
      fi
      ;;
    0)
      if [ -f "$UDHCPC_CONF" ]; then
        tmp="${CONF_DIR}/udhcpc.conf.restore.$$"
        awk '!/^[[:space:]]*RESOLV_CONF[[:space:]]*=[[:space:]]*"?no"?[[:space:]]*$/' "$UDHCPC_CONF" > "$tmp"
        cat "$tmp" > "$UDHCPC_CONF"
        rm -f "$tmp"
      fi
      ;;
  esac
  rm -f "$UDHCPC_BACKUP_FILE"
}

show_system_dns() {
  printf '\nCurrent Alpine system DNS (%s):\n' "$RESOLV_CONF"
  if [ -r "$RESOLV_CONF" ]; then
    found=0
    while IFS= read -r dns; do
      [ -n "$dns" ] || continue
      printf '  - %s\n' "$dns"
      found=1
    done <<EOF_DNS
$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' "$RESOLV_CONF")
EOF_DNS
    [ "$found" = "1" ] || printf '%s\n' '  (no nameserver entries)'
  else
    printf '%s\n' '  (unavailable)'
  fi
  if [ -f "$DNS_BACKUP_FILE" ]; then
    printf 'Original DNS backup: %s\n' "$DNS_BACKUP_FILE"
  else
    printf '%s\n' 'Original DNS backup: none'
  fi
  if [ -f "$UDHCPC_CONF" ] && grep -Eq '^[[:space:]]*RESOLV_CONF[[:space:]]*=[[:space:]]*"?no"?' "$UDHCPC_CONF"; then
    printf '%s\n' 'DHCP DNS overwrite: disabled (persistent static DNS)'
  else
    printf '%s\n' 'DHCP DNS overwrite: enabled / default'
  fi
}

set_system_dns() {
  [ "$#" -ge 1 ] || die "At least one DNS server is required."
  [ "$#" -le 3 ] || die "Use at most 3 DNS servers."
  for dns in "$@"; do
    validate_dns_server "$dns" || die "Invalid DNS server IP: ${dns}"
  done
  backup_system_dns
  disable_dhcp_dns_overwrite
  tmp="${CONF_DIR}/resolv.conf.new.$$"
  : > "$tmp"
  for dns in "$@"; do
    printf 'nameserver %s\n' "$dns" >> "$tmp"
  done
  if [ -r "$RESOLV_CONF" ]; then
    awk '!/^[[:space:]]*nameserver[[:space:]]+/' "$RESOLV_CONF" >> "$tmp"
  fi
  cat "$tmp" > "$RESOLV_CONF"
  rm -f "$tmp"
  log "System DNS updated: $*"
  log "Configured udhcpc not to overwrite /etc/resolv.conf, so the selected DNS persists across DHCP renewals/reboots."
  show_system_dns
}

restore_system_dns() {
  [ -f "$DNS_BACKUP_FILE" ] || die "No DNS backup is available to restore."
  cat "$DNS_BACKUP_FILE" > "$RESOLV_CONF"
  rm -f "$DNS_BACKUP_FILE"
  restore_udhcpc_dns_behavior
  log "Original system DNS and DHCP DNS behavior restored."
  show_system_dns
}

configure_system_dns_on_install() {
  if [ -n "${LOCAL_DNS:-}" ]; then
    set -- $LOCAL_DNS
    set_system_dns "$@"
    return 0
  fi
  [ -t 0 ] || return 0
  printf 'Set Alpine local DNS now? [y/N]: '
  read -r answer || return 0
  case "$answer" in
    y|Y|yes|YES)
      printf 'DNS server IPs (space separated, max 3; e.g. 1.1.1.1 8.8.8.8): '
      read -r dns_line || return 0
      [ -n "$(trim_value "$dns_line")" ] || { warn "No DNS entered; skipped."; return 0; }
      set -- $dns_line
      set_system_dns "$@"
      ;;
    *) log "Keeping current Alpine system DNS." ;;
  esac
}

conf_get() {
  # Usage: conf_get key
  key="$1"
  [ -f "$CONF_FILE" ] || return 1
  awk -F= -v key="$key" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$CONF_FILE"
}

config_exists() {
  [ -s "$CONF_FILE" ]
}

service_exists() {
  [ -x "$INIT_FILE" ]
}

binary_exists() {
  [ -x "$BIN_FILE" ]
}

validate_port() {
  port="$1"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

tcp_port_in_use() {
  port="$1"
  ss -lnt 2>/dev/null | awk 'NR > 1 {print $4}' | grep -Eq "(^|[:.])${port}$"
}

udp_port_in_use() {
  port="$1"
  ss -lun 2>/dev/null | awk 'NR > 1 {print $4}' | grep -Eq "(^|[:.])${port}$"
}

port_in_use_for_major() {
  port="$1"
  major="$2"
  tcp_port_in_use "$port" && return 0
  if [ "$major" = "5" ]; then
    udp_port_in_use "$port" && return 0
  fi
  return 1
}

random_port() {
  major="${1:-6}"
  while :; do
    n="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
    port=$((10000 + n % 50001))
    if ! port_in_use_for_major "$port" "$major"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
}

random_psk() {
  openssl rand -hex 16
}

configure_port_on_install() {
  major="$1"
  old_port="$(current_port 2>/dev/null || true)"

  if [ -n "${PORT:-}" ]; then
    validate_port "$PORT" || die "PORT must be an integer from 1 to 65535."
    if [ "$PORT" != "$old_port" ] && port_in_use_for_major "$PORT" "$major"; then
      if [ "$major" = "5" ]; then
        die "TCP or UDP port ${PORT} is already in use. Snell v5 needs the selected port available on both protocols."
      fi
      die "TCP port ${PORT} is already in use."
    fi
    return 0
  fi

  [ -t 0 ] || { PORT="${old_port:-$(random_port "$major")}"; export PORT; return 0; }
  suggested_port="${old_port:-$(random_port "$major")}"
  suggested_port="$(trim_value "$suggested_port")"
  while :; do
    printf 'Listen port [%s]: ' "$suggested_port"
    read -r selected_port || die "Unable to read listen port."
    selected_port="$(trim_value "$selected_port")"
    [ -n "$selected_port" ] || selected_port="$suggested_port"
    if ! validate_port "$selected_port"; then
      warn "Enter a port from 1 to 65535."
      continue
    fi
    if [ "$selected_port" != "$old_port" ] && port_in_use_for_major "$selected_port" "$major"; then
      if [ "$major" = "5" ]; then
        warn "TCP or UDP port ${selected_port} is already in use."
      else
        warn "TCP port ${selected_port} is already in use."
      fi
      continue
    fi
    PORT="$selected_port"
    export PORT
    log "Listen port selected: ${PORT}."
    return 0
  done
}

validate_tfo_state() {
  case "$1" in
    1|on|enable|enabled|true|yes) return 0 ;;
    0|off|disable|disabled|false|no) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_tfo_state() {
  case "$1" in
    1|on|enable|enabled|true|yes) printf '1\n' ;;
    0|off|disable|disabled|false|no) printf '0\n' ;;
    *) return 1 ;;
  esac
}

current_client_tfo() {
  if [ -n "${CLIENT_TFO:-}" ]; then
    normalize_tfo_state "$CLIENT_TFO" 2>/dev/null || printf '0\n'
    return 0
  fi
  saved="$(state_get CLIENT_TFO 2>/dev/null || true)"
  [ -n "$saved" ] || saved=0
  normalize_tfo_state "$saved" 2>/dev/null || printf '0\n'
}

set_client_tfo() {
  state="$(normalize_tfo_state "$1" 2>/dev/null || true)"
  [ -n "$state" ] || die "Use: tfo on|off"
  state_set CLIENT_TFO "$state"
  CLIENT_TFO="$state"
  export CLIENT_TFO
  if [ "$state" = "1" ]; then
    log "Surge TCP Fast Open (TFO) enabled for generated client configuration."
  else
    log "Surge TCP Fast Open (TFO) disabled for generated client configuration."
  fi
}

configure_tfo_on_install() {
  if [ -n "${CLIENT_TFO:-}" ]; then
    set_client_tfo "$CLIENT_TFO"
    return 0
  fi
  [ -t 0 ] || { state_set CLIENT_TFO 0; return 0; }
  printf 'Enable Surge TCP Fast Open (TFO)? [y/N]: '
  read -r answer || answer=''
  case "$answer" in
    y|Y|yes|YES) set_client_tfo 1 ;;
    *) set_client_tfo 0 ;;
  esac
}

normalize_bool_state() {
  case "$1" in
    1|on|enable|enabled|true|yes|y|Y) printf '1\n' ;;
    0|off|disable|disabled|false|no|n|N) printf '0\n' ;;
    *) return 1 ;;
  esac
}

shadowtls_enabled() {
  value="$(state_get SHADOWTLS_ENABLED 2>/dev/null || true)"
  [ "$(normalize_bool_state "${value:-0}" 2>/dev/null || printf '0')" = "1" ]
}

shadowtls_binary_exists() { [ -x "$SHADOWTLS_BIN" ]; }
shadowtls_service_exists() { [ -x "$SHADOWTLS_INIT" ]; }

validate_shadowtls_sni() {
  sni="$(trim_value "$1")"
  [ -n "$sni" ] || return 1
  case "$sni" in
    *[!A-Za-z0-9.-]*|.*|*.|*..*|*:* ) return 1 ;;
  esac
  return 0
}

validate_shadowtls_password() {
  password="$1"
  [ -n "$password" ] || return 1
  case "$password" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

random_shadowtls_password() {
  openssl rand -hex 16
}

shadowtls_arch_target() {
  case "$SNELL_ARCH" in
    amd64) printf 'x86_64-unknown-linux-musl\n' ;;
    aarch64) printf 'aarch64-unknown-linux-musl\n' ;;
    armv7l) printf 'armv7-unknown-linux-musleabihf\n' ;;
    i386) return 1 ;;
    *) return 1 ;;
  esac
}

get_shadowtls_latest_version() {
  if [ -n "${SHADOWTLS_RELEASE_VERSION:-}" ]; then
    printf '%s\n' "$SHADOWTLS_RELEASE_VERSION"
    return 0
  fi
  version="$(curl -fsSL --retry 2 --connect-timeout 10 "$SHADOWTLS_RELEASE_API" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  if [ -z "$version" ]; then
    effective="$(curl -fsSL --retry 2 --connect-timeout 10 -o /dev/null -w '%{url_effective}' "$SHADOWTLS_LATEST_PAGE" 2>/dev/null || true)"
    version="$(printf '%s' "$effective" | sed -n 's#.*/tag/##p')"
  fi
  if [ -z "$version" ]; then
    warn "Unable to resolve the latest ShadowTLS release; using fallback ${SHADOWTLS_FALLBACK_VERSION}."
    version="$SHADOWTLS_FALLBACK_VERSION"
  fi
  printf '%s\n' "$version"
}

resolve_shadowtls_url() {
  if [ -n "${SHADOWTLS_URL:-}" ]; then
    url="$SHADOWTLS_URL"
  else
    target="$(shadowtls_arch_target 2>/dev/null || true)"
    [ -n "$target" ] || die "ShadowTLS prebuilt binaries used by this script are not available for ${SNELL_ARCH}. Snell v5 itself may still work without ShadowTLS."
    version="$(get_shadowtls_latest_version)"
    url="https://github.com/ihciah/shadow-tls/releases/download/${version}/shadow-tls-${target}"
  fi
  case "$url" in
    https://github.com/ihciah/shadow-tls/releases/download/*/shadow-tls-*) ;;
    *) die "Refusing unexpected ShadowTLS URL: ${url}. Use an official ihciah/shadow-tls GitHub release URL." ;;
  esac
  printf '%s\n' "$url"
}

download_shadowtls_binary() {
  url="$(resolve_shadowtls_url)"
  log "Downloading ShadowTLS: ${url}"
  tmp="${SHADOWTLS_BIN}.new.$$"
  rm -f "$tmp"
  curl -fL --retry 3 --connect-timeout 10 "$url" -o "$tmp" || { rm -f "$tmp"; die "Failed to download ShadowTLS."; }
  [ -s "$tmp" ] || { rm -f "$tmp"; die "Downloaded ShadowTLS binary is empty."; }
  chmod 755 "$tmp"
  if ! "$tmp" --help >/dev/null 2>&1 && ! "$tmp" server --help >/dev/null 2>&1; then
    rm -f "$tmp"
    die "Downloaded ShadowTLS binary cannot run on this Alpine/CPU."
  fi
  mv "$tmp" "$SHADOWTLS_BIN"
  release="$(printf '%s' "$url" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p')"
  [ -n "$release" ] && state_set SHADOWTLS_RELEASE "$release" || true
}

current_shadowtls_port() { state_get SHADOWTLS_PORT 2>/dev/null || true; }
current_shadowtls_sni() { state_get SHADOWTLS_SNI 2>/dev/null || true; }
current_shadowtls_password() { state_get SHADOWTLS_PASSWORD 2>/dev/null || true; }

shadowtls_public_port_available() {
  port="$1"
  old_port="$(current_shadowtls_port)"
  [ "$port" = "$old_port" ] && shadowtls_service_exists && return 0
  ! tcp_port_in_use "$port"
}

suggest_shadowtls_port() {
  backend="$1"
  old="$(current_shadowtls_port)"
  if validate_port "$old" 2>/dev/null && [ "$old" != "$backend" ]; then
    printf '%s\n' "$old"
    return 0
  fi
  if [ "$backend" != "8443" ] && ! tcp_port_in_use 8443; then
    printf '8443\n'
    return 0
  fi
  while :; do
    p="$(random_port 6)"
    [ "$p" != "$backend" ] && ! tcp_port_in_use "$p" && { printf '%s\n' "$p"; return 0; }
  done
}

set_shadowtls_details() {
  backend_port="$1"
  public_port="$2"
  sni="$3"
  password="$4"
  validate_port "$public_port" || die "ShadowTLS public port must be 1-65535."
  [ "$public_port" != "$backend_port" ] || die "ShadowTLS public port must differ from the Snell backend port."
  shadowtls_public_port_available "$public_port" || die "TCP port ${public_port} is already in use."
  validate_shadowtls_sni "$sni" || die "Invalid ShadowTLS SNI hostname: ${sni}"
  validate_shadowtls_password "$password" || die "ShadowTLS password must use only letters, digits, dot, underscore or hyphen."
  state_set SHADOWTLS_PORT "$public_port"
  state_set SHADOWTLS_SNI "$sni"
  state_set SHADOWTLS_PASSWORD "$password"
  state_set SHADOWTLS_VERSION 3
  state_set SHADOWTLS_ENABLED 1
}

configure_shadowtls_on_install() {
  target_major="$1"
  backend_port="$2"
  if [ "$target_major" != "5" ]; then
    SHADOWTLS_REQUESTED=0
    export SHADOWTLS_REQUESTED
    return 0
  fi

  current=0
  shadowtls_enabled && current=1
  if [ -n "${SHADOWTLS_ENABLE:-}" ]; then
    enabled="$(normalize_bool_state "$SHADOWTLS_ENABLE" 2>/dev/null || true)"
    [ -n "$enabled" ] || die "SHADOWTLS_ENABLE must be 0 or 1."
  elif [ -t 0 ]; then
    if [ "$current" = "1" ]; then prompt='Enable ShadowTLS v3 for Snell v5? [Y/n]: '; else prompt='Enable ShadowTLS v3 for Snell v5? [y/N]: '; fi
    printf '%s' "$prompt"
    read -r answer || answer=''
    case "$answer" in
      y|Y|yes|YES) enabled=1 ;;
      n|N|no|NO) enabled=0 ;;
      '') enabled="$current" ;;
      *) enabled="$current" ;;
    esac
  else
    enabled="$current"
  fi

  if [ "$enabled" != "1" ]; then
    state_set SHADOWTLS_ENABLED 0
    SHADOWTLS_REQUESTED=0
    export SHADOWTLS_REQUESTED
    return 0
  fi

  [ "$SNELL_ARCH" != "i386" ] || die "ShadowTLS support is unavailable on i386 in this script because the upstream release set does not publish the target used by the reference implementation. Install Snell v5 without ShadowTLS on i386."
  suggested="$(suggest_shadowtls_port "$backend_port")"
  public_port="${SHADOWTLS_PORT:-$(current_shadowtls_port)}"
  [ -n "$public_port" ] || public_port="$suggested"
  if [ -t 0 ] && [ -z "${SHADOWTLS_PORT:-}" ]; then
    while :; do
      printf 'ShadowTLS public TCP port [%s]: ' "$public_port"
      read -r selected || die "Unable to read ShadowTLS port."
      selected="$(trim_value "$selected")"
      [ -n "$selected" ] || selected="$public_port"
      if ! validate_port "$selected" || [ "$selected" = "$backend_port" ]; then
        warn "Choose a free TCP port different from the Snell backend port ${backend_port}."
        continue
      fi
      if ! shadowtls_public_port_available "$selected"; then
        warn "TCP port ${selected} is already in use."
        continue
      fi
      public_port="$selected"
      break
    done
  fi

  sni="${SHADOWTLS_SNI:-$(current_shadowtls_sni)}"
  [ -n "$sni" ] || sni="$DEFAULT_SHADOWTLS_SNI"
  if [ -t 0 ] && [ -z "${SHADOWTLS_SNI:-}" ]; then
    while :; do
      printf 'ShadowTLS SNI [%s]: ' "$sni"
      read -r selected_sni || die "Unable to read ShadowTLS SNI."
      selected_sni="$(trim_value "$selected_sni")"
      [ -n "$selected_sni" ] || selected_sni="$sni"
      if validate_shadowtls_sni "$selected_sni"; then sni="$selected_sni"; break; fi
      warn "Enter a hostname such as www.icloud.com."
    done
  fi

  password="${SHADOWTLS_PASSWORD:-$(current_shadowtls_password)}"
  [ -n "$password" ] || password="$(random_shadowtls_password)"
  set_shadowtls_details "$backend_port" "$public_port" "$sni" "$password"
  SHADOWTLS_REQUESTED=1
  export SHADOWTLS_REQUESTED
  log "ShadowTLS v3 selected: public TCP/${public_port}, SNI ${sni}."
}

enable_shadowtls_kernel_tfo() {
  sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
  mkdir -p /etc/sysctl.d 2>/dev/null || true
  printf '%s\n' 'net.ipv4.tcp_fastopen = 3' > /etc/sysctl.d/99-shadowtls-tfo.conf 2>/dev/null || true
}

install_shadowtls_openrc_service() {
  shadowtls_enabled || return 0
  backend_port="$(current_port)" || die "Cannot determine Snell backend port for ShadowTLS."
  public_port="$(current_shadowtls_port)"
  sni="$(current_shadowtls_sni)"
  password="$(current_shadowtls_password)"
  [ -x "$SHADOWTLS_BIN" ] || die "ShadowTLS binary is missing."
  enable_shadowtls_kernel_tfo
  touch "$SHADOWTLS_LOG"
  cat > "$SHADOWTLS_INIT" <<EOF_STLS
#!/sbin/openrc-run
name="ShadowTLS for Snell"
description="ShadowTLS v3 frontend for Snell v5"
export MONOIO_FORCE_LEGACY_DRIVER=1
export RUST_LOG=info
command="${SHADOWTLS_BIN}"
command_args="--fastopen --v3 server --listen 0.0.0.0:${public_port} --server 127.0.0.1:${backend_port} --tls ${sni} --password ${password}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${SHADOWTLS_LOG}"
error_log="${SHADOWTLS_LOG}"

 depend() {
    need net snell
    after firewall snell
 }
EOF_STLS
  chmod 755 "$SHADOWTLS_INIT"
  rc-update add "$SHADOWTLS_SERVICE" default >/dev/null 2>&1 || true
}

start_or_restart_shadowtls() {
  shadowtls_service_exists || return 1
  if rc-service "$SHADOWTLS_SERVICE" status >/dev/null 2>&1; then
    rc-service "$SHADOWTLS_SERVICE" restart
  else
    rc-service "$SHADOWTLS_SERVICE" start
  fi
  sleep 1
  rc-service "$SHADOWTLS_SERVICE" status >/dev/null 2>&1
}

stop_remove_shadowtls_service() {
  if shadowtls_service_exists; then
    rc-service "$SHADOWTLS_SERVICE" stop >/dev/null 2>&1 || true
    rc-update del "$SHADOWTLS_SERVICE" default >/dev/null 2>&1 || true
    rm -f "$SHADOWTLS_INIT"
  fi
}

refresh_shadowtls_service_if_enabled() {
  if shadowtls_enabled; then
    install_shadowtls_openrc_service
    start_or_restart_shadowtls || die "ShadowTLS failed to restart. Check ${SHADOWTLS_LOG}."
  fi
}

show_shadowtls() {
  printf '\nShadowTLS v3:\n'
  if ! shadowtls_enabled; then
    printf '  Status: disabled\n'
    return 0
  fi
  public_port="$(current_shadowtls_port)"
  sni="$(current_shadowtls_sni)"
  password="$(current_shadowtls_password)"
  release="$(state_get SHADOWTLS_RELEASE 2>/dev/null || true)"
  if rc-service "$SHADOWTLS_SERVICE" status >/dev/null 2>&1; then svc=running; else svc=stopped; fi
  printf '  Status:      enabled (%s)\n' "$svc"
  printf '  Public port: %s/tcp\n' "$public_port"
  printf '  SNI:         %s\n' "$sni"
  printf '  Password:    %s\n' "$password"
  printf '  Protocol:    v3\n'
  printf '  Binary:      %s\n' "${release:-unknown}"
}

enable_shadowtls() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  [ "$major" = "5" ] || die "ShadowTLS integration in this script is supported for Snell v5 only."
  ensure_dependencies
  backend_port="$(current_port)" || die "Cannot determine Snell backend port."
  SHADOWTLS_ENABLE=1
  export SHADOWTLS_ENABLE
  configure_shadowtls_on_install 5 "$backend_port"
  download_shadowtls_binary
  psk="$(conf_get psk)"
  ipv6="$(current_ipv6_enabled)"
  # state is enabled now, so this rewrites Snell to 127.0.0.1:<port>.
  apply_config_change 5 "$backend_port" "$psk" "$ipv6" prefer-ipv4 default
  install_shadowtls_openrc_service
  if ! start_or_restart_shadowtls; then
    warn "ShadowTLS failed to start; restoring direct Snell v5 listening."
    state_set SHADOWTLS_ENABLED 0
    apply_config_change 5 "$backend_port" "$psk" "$ipv6" prefer-ipv4 default || true
    stop_remove_shadowtls_service
    die "ShadowTLS enable failed. Check ${SHADOWTLS_LOG}."
  fi
  show_config
}

disable_shadowtls() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  [ "$major" = "5" ] || die "ShadowTLS integration in this script is supported for Snell v5 only."
  backend_port="$(current_port)" || die "Cannot determine Snell backend port."
  psk="$(conf_get psk)"
  ipv6="$(current_ipv6_enabled)"
  stop_remove_shadowtls_service
  state_set SHADOWTLS_ENABLED 0
  apply_config_change 5 "$backend_port" "$psk" "$ipv6" prefer-ipv4 default
  log "ShadowTLS disabled; Snell v5 is directly exposed again."
  show_config
}

update_shadowtls() {
  shadowtls_enabled || die "ShadowTLS is not enabled."
  ensure_dependencies
  download_shadowtls_binary
  install_shadowtls_openrc_service
  start_or_restart_shadowtls || die "Updated ShadowTLS binary failed to start. Check ${SHADOWTLS_LOG}."
  log "ShadowTLS updated."
  show_shadowtls
}

shadowtls_menu() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  [ "$major" = "5" ] || { warn "ShadowTLS menu is available for Snell v5 only."; return 0; }
  show_shadowtls
  printf '%s\n' '1) Enable / reconfigure ShadowTLS v3'
  printf '%s\n' '2) Disable ShadowTLS'
  printf '%s\n' '3) Update ShadowTLS binary'
  printf '%s\n' '4) Show ShadowTLS details'
  printf '%s\n' '0) Back'
  printf 'Select: '
  read -r c || return 0
  case "$c" in
    1) enable_shadowtls ;;
    2) disable_shadowtls ;;
    3) update_shadowtls ;;
    4) show_shadowtls ;;
    0) return 0 ;;
    *) warn "Invalid selection." ;;
  esac
}

validate_mode() {
  case "$1" in
    default|unshaped) return 0 ;;
    unsafe-raw)
      [ "${ALLOW_UNSAFE_RAW:-0}" = "1" ] || return 2
      return 0
      ;;
    *) return 1 ;;
  esac
}

validate_dns() {
  case "$1" in
    default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) return 0 ;;
    *) return 1 ;;
  esac
}

listen_from_port_ipv6() {
  port="$1"
  ipv6="$2"
  if [ "$ipv6" = "1" ]; then
    printf '0.0.0.0:%s,[::]:%s\n' "$port" "$port"
  else
    printf '0.0.0.0:%s\n' "$port"
  fi
}

current_ipv6_enabled() {
  major="$(current_snell_major 2>/dev/null || printf '6')"
  if [ "$major" = "5" ]; then
    value="$(conf_get ipv6 2>/dev/null || printf 'false')"
    case "$value" in
      true|1|yes|on) printf '1\n' ;;
      *) printf '0\n' ;;
    esac
    return 0
  fi

  listen="$(conf_get listen 2>/dev/null || true)"
  case "$listen" in
    *'[::]:'*) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

current_port() {
  listen="$(conf_get listen 2>/dev/null || true)"
  first_listen="$(printf '%s' "$listen" | cut -d, -f1 | tr -d '[:space:]')"
  port="$(printf '%s' "$first_listen" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p')"
  [ -n "$port" ] || return 1
  printf '%s\n' "$port"
}

write_config_v5() {
  port="$1"
  psk="$2"
  ipv6="$3"
  if [ "$ipv6" = "1" ]; then ipv6_value=true; else ipv6_value=false; fi
  bind_host="0.0.0.0"
  if shadowtls_enabled; then
    bind_host="127.0.0.1"
  fi

  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  umask 077
  tmp="${CONF_FILE}.tmp.$$"
  cat > "$tmp" <<EOF_CONFIG
[snell-server]
listen = ${bind_host}:${port}
psk = ${psk}
ipv6 = ${ipv6_value}
EOF_CONFIG
  chmod 600 "$tmp"
  mv "$tmp" "$CONF_FILE"
}

write_config_v6() {
  port="$1"
  psk="$2"
  ipv6="$3"
  dns_pref="$4"
  mode="$5"
  listen="$(listen_from_port_ipv6 "$port" "$ipv6")"

  mkdir -p "$CONF_DIR"
  chmod 700 "$CONF_DIR"
  umask 077
  tmp="${CONF_FILE}.tmp.$$"
  cat > "$tmp" <<EOF_CONFIG
[snell-server]
listen = ${listen}
psk = ${psk}
dns-ip-preference = ${dns_pref}
mode = ${mode}
EOF_CONFIG
  chmod 600 "$tmp"
  mv "$tmp" "$CONF_FILE"
}

write_config_for_major() {
  major="$1"
  port="$2"
  psk="$3"
  ipv6="$4"
  dns_pref="${5:-prefer-ipv4}"
  mode="${6:-default}"
  case "$major" in
    5) write_config_v5 "$port" "$psk" "$ipv6" ;;
    6) write_config_v6 "$port" "$psk" "$ipv6" "$dns_pref" "$mode" ;;
    *) die "Unsupported Snell major version: ${major}" ;;
  esac
}

create_install_config() {
  target_major="$1"
  old_major="$(current_snell_major 2>/dev/null || true)"

  old_port="$(current_port 2>/dev/null || true)"
  port="${PORT:-${old_port:-}}"
  [ -n "$port" ] || port="$(random_port "$target_major")"
  validate_port "$port" || die "PORT must be an integer from 1 to 65535."

  old_psk="$(conf_get psk 2>/dev/null || true)"
  psk="${PSK:-${old_psk:-$(random_psk)}}"
  [ -n "$psk" ] || die "PSK cannot be empty."

  if [ -n "${ENABLE_IPV6:-}" ]; then
    ipv6="$ENABLE_IPV6"
  elif [ -n "$old_major" ] && [ "$old_major" = "$target_major" ]; then
    ipv6="$(current_ipv6_enabled 2>/dev/null || printf '0')"
  else
    ipv6=0
  fi
  case "$ipv6" in 0|1) ;; *) die "ENABLE_IPV6 must be 0 or 1." ;; esac

  if [ "$target_major" = "6" ]; then
    if [ "$old_major" = "6" ]; then
      old_mode="$(conf_get mode 2>/dev/null || printf 'default')"
      old_dns="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
    else
      old_mode=default
      old_dns=prefer-ipv4
    fi
    mode="${MODE:-$old_mode}"
    if validate_mode "$mode"; then
      :
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        die "unsafe-raw disables encryption. Set ALLOW_UNSAFE_RAW=1 only if you intentionally want it."
      fi
      die "Invalid MODE: ${mode}"
    fi
    dns_pref="${DNS_PREFERENCE:-$old_dns}"
    validate_dns "$dns_pref" || die "Invalid DNS_PREFERENCE: ${dns_pref}"
    write_config_v6 "$port" "$psk" "$ipv6" "$dns_pref" "$mode"
  else
    write_config_v5 "$port" "$psk" "$ipv6"
  fi

  if [ -n "$old_major" ] && [ "$old_major" != "$target_major" ]; then
    log "Converted server configuration from Snell v${old_major} to v${target_major}."
  else
    log "Prepared Snell v${target_major} configuration at ${CONF_FILE}."
  fi
}

resolve_download_url() {
  major="$1"
  validate_snell_major "$major" || die "Invalid Snell major version: ${major}"

  if [ -n "${SNELL_URL:-}" ]; then
    url="$SNELL_URL"
  else
    log "Resolving current Snell v${major} download from Surge..." >&2
    page="$(curl -fsSL --retry 3 --connect-timeout 10 "$RELEASE_PAGE")" || die "Unable to fetch the official Snell release page."
    url="$(printf '%s\n' "$page" \
      | grep -Eo "https://dl\\.nssurge\\.com/snell/snell-server-v${major}[^[:space:]\"'<>)]*-linux-${SNELL_ARCH}\\.zip" \
      | tail -n 1 || true)"
    [ -n "$url" ] || die "Could not find a Snell v${major} package for ${SNELL_ARCH}. Set SNELL_URL manually if Surge changed the release-page format."
  fi

  case "$url" in
    https://dl.nssurge.com/snell/snell-server-v"${major}"*-linux-"${SNELL_ARCH}".zip) ;;
    *) die "Refusing unexpected Snell v${major} download URL: ${url}" ;;
  esac
  printf '%s\n' "$url"
}

extract_version_from_url() {
  url="$1"
  basename "$url" | sed -n 's/^snell-server-\(v[56][^-]*\)-linux-.*\.zip$/\1/p'
}

check_binary_compat() {
  file="$1"
  output="$($file --help 2>&1 || true)"
  case "$output" in
    *"not found"*|*"Error loading shared library"*|*"symbol not found"*)
      printf '%s\n' "$output" >&2
      return 1
      ;;
  esac
  return 0
}

download_binary_to() {
  destination="$1"
  major="$2"
  url="$(resolve_download_url "$major")"
  version="$(extract_version_from_url "$url")"
  [ -n "$version" ] || version="v${major} (unknown build)"

  log "Downloading ${version}: ${url}"
  tmp_dir="$(mktemp -d)"
  curl -fL --retry 3 --connect-timeout 10 "$url" -o "$tmp_dir/snell.zip"
  unzip -oq "$tmp_dir/snell.zip" -d "$tmp_dir/unpack"
  src="$(find "$tmp_dir/unpack" -type f -name snell-server -print | head -n 1)"
  [ -n "$src" ] || { rm -rf "$tmp_dir"; die "snell-server was not found in the downloaded archive."; }

  cp "$src" "$destination"
  chmod 755 "$destination"
  if ! check_binary_compat "$destination"; then
    rm -f "$destination"
    rm -rf "$tmp_dir"
    die "The Snell v${major} binary could not run with Alpine ${ALPINE_VERSION} and the available glibc compatibility layer (${GLIBC_COMPAT:-unknown})."
  fi
  rm -rf "$tmp_dir"
  printf '%s\n' "$version" > "${destination}.version"
}

install_openrc_service() {
  major="$1"
  touch "$LOG_FILE"
  cat > "$INIT_FILE" <<EOF_INIT
#!/sbin/openrc-run

name="Snell Server"
description="Snell v${major} Proxy Server"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell/snell-server.conf"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/snell.log"
error_log="/var/log/snell.log"

depend() {
    need net
    after firewall
}
EOF_INIT
  chmod 755 "$INIT_FILE"
  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
}

start_or_restart() {
  if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
    rc-service "$SERVICE_NAME" restart
  else
    rc-service "$SERVICE_NAME" start
  fi
  sleep 1
  if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
    tail -n 50 "$LOG_FILE" 2>/dev/null || true
    return 1
  fi
  return 0
}

installed_version() {
  if [ -s "${BIN_FILE}.version" ]; then
    cat "${BIN_FILE}.version"
    return 0
  fi
  if binary_exists; then
    out="$($BIN_FILE --help 2>&1 || true)"
    printf '%s\n' "$out" | sed -n 's/.*\(v[56]\.[0-9][^[:space:]]*\).*/\1/p' | head -n 1
  fi
}

install_snell() {
  select_snell_major_on_install
  target_major="$TARGET_MAJOR"
  first_install=0
  config_exists || first_install=1

  ensure_dependencies
  ensure_server_host
  configure_port_on_install "$target_major"
  configure_shadowtls_on_install "$target_major" "$PORT"
  if [ "$first_install" = "1" ]; then
    configure_system_dns_on_install
    configure_tfo_on_install
  elif [ -n "${CLIENT_TFO:-}" ]; then
    set_client_tfo "$CLIENT_TFO"
  fi
  if [ "$target_major" = "5" ] && shadowtls_enabled; then
    download_shadowtls_binary
  fi

  config_backup="${CONF_FILE}.install.bak.$$"
  had_config=0
  if config_exists; then
    had_config=1
    cp "$CONF_FILE" "$config_backup"
    chmod 600 "$config_backup"
  fi
  create_install_config "$target_major"

  tmp_bin="${BIN_FILE}.new.$$"
  backup_bin="${BIN_FILE}.bak.$$"
  backup_ver="${BIN_FILE}.version.bak.$$"
  had_binary=0
  rm -f "$tmp_bin" "${tmp_bin}.version" "$backup_bin" "$backup_ver"
  download_binary_to "$tmp_bin" "$target_major"

  if binary_exists; then
    had_binary=1
    cp "$BIN_FILE" "$backup_bin"
    [ -f "${BIN_FILE}.version" ] && cp "${BIN_FILE}.version" "$backup_ver" || true
  fi

  mv "$tmp_bin" "$BIN_FILE"
  if [ -f "${tmp_bin}.version" ]; then
    mv "${tmp_bin}.version" "${BIN_FILE}.version"
  fi
  chmod 755 "$BIN_FILE"
  install_openrc_service "$target_major"

  if ! start_or_restart; then
    warn "Snell v${target_major} failed to start; rolling back."
    if [ "$had_binary" = "1" ]; then
      mv "$backup_bin" "$BIN_FILE"
      if [ -f "$backup_ver" ]; then
        mv "$backup_ver" "${BIN_FILE}.version"
      else
        rm -f "${BIN_FILE}.version"
      fi
      chmod 755 "$BIN_FILE"
    else
      rm -f "$BIN_FILE" "${BIN_FILE}.version"
    fi
    if [ "$had_config" = "1" ]; then
      mv "$config_backup" "$CONF_FILE"
    else
      rm -f "$CONF_FILE" "$config_backup"
    fi
    if [ "$had_binary" = "1" ]; then
      old_major="$(installed_major_from_version 2>/dev/null || true)"
      [ -n "$old_major" ] && install_openrc_service "$old_major" || true
      start_or_restart || true
    fi
    die "Install/repair failed; previous binary/configuration were restored when available."
  fi

  state_set SNELL_MAJOR "$target_major"

  if [ "$target_major" = "5" ] && shadowtls_enabled; then
    install_shadowtls_openrc_service
    if ! start_or_restart_shadowtls; then
      warn "ShadowTLS failed to start. Falling back to direct Snell v5 so the server stays reachable."
      stop_remove_shadowtls_service
      state_set SHADOWTLS_ENABLED 0
      psk_now="$(conf_get psk)"
      ipv6_now="$(current_ipv6_enabled)"
      write_config_v5 "$PORT" "$psk_now" "$ipv6_now"
      start_or_restart || true
      die "Snell v5 installed, but ShadowTLS setup failed. Check ${SHADOWTLS_LOG}."
    fi
  elif [ "$target_major" = "6" ]; then
    stop_remove_shadowtls_service
    state_set SHADOWTLS_ENABLED 0
  fi

  rm -f "$backup_bin" "$backup_ver" "$config_backup"
  log "Snell v${target_major} installation completed."
  if [ "$target_major" = "5" ]; then
    if shadowtls_enabled; then
      warn "ShadowTLS is TCP-only. The generated Surge policy sets block-quic=true. Normal UDP still works through Snell v5 UDP-over-TCP."
    else
      warn "Snell v5 QUIC Proxy Mode uses UDP on the same port. Allow both TCP/${PORT} and UDP/${PORT} in your VPS/cloud firewall."
    fi
  fi
  show_config
}

update_snell() {
  binary_exists || die "Snell is not installed. Run: $0 install"
  major="$(current_snell_major 2>/dev/null || true)"
  validate_snell_major "$major" || die "Cannot determine whether the installed server is Snell v5 or v6. Re-run: $0 install"
  if [ "$major" = "6" ] && [ "$SNELL_ARCH" = "armv7l" ]; then
    die "Official Snell v6 does not provide an armv7l package."
  fi
  ensure_dependencies

  tmp_bin="${BIN_FILE}.new.$$"
  backup_bin="${BIN_FILE}.bak.$$"
  backup_ver="${BIN_FILE}.version.bak.$$"
  rm -f "$tmp_bin" "${tmp_bin}.version" "$backup_bin" "$backup_ver"

  download_binary_to "$tmp_bin" "$major"
  new_version="$(cat "${tmp_bin}.version" 2>/dev/null || true)"
  old_version="$(installed_version 2>/dev/null || true)"

  cp "$BIN_FILE" "$backup_bin"
  [ -f "${BIN_FILE}.version" ] && cp "${BIN_FILE}.version" "$backup_ver" || true

  mv "$tmp_bin" "$BIN_FILE"
  if [ -f "${tmp_bin}.version" ]; then
    mv "${tmp_bin}.version" "${BIN_FILE}.version"
  fi
  chmod 755 "$BIN_FILE"
  install_openrc_service "$major"

  if ! start_or_restart; then
    warn "New binary failed to start; rolling back."
    mv "$backup_bin" "$BIN_FILE"
    if [ -f "$backup_ver" ]; then
      mv "$backup_ver" "${BIN_FILE}.version"
    else
      rm -f "${BIN_FILE}.version"
    fi
    chmod 755 "$BIN_FILE"
    start_or_restart || true
    die "Update failed and the previous binary was restored."
  fi

  state_set SNELL_MAJOR "$major"
  rm -f "$backup_bin" "$backup_ver"
  if [ -n "$old_version" ] && [ "$old_version" = "$new_version" ]; then
    log "Reinstalled ${new_version}; it was already the current resolved v${major} build."
  else
    log "Updated Snell v${major}: ${old_version:-unknown} -> ${new_version:-unknown}."
  fi
}

require_config() {
  config_exists || die "Snell configuration not found. Run: $0 install"
}

apply_config_change() {
  major="$1"
  port="$2"
  psk="$3"
  ipv6="$4"
  dns_pref="${5:-prefer-ipv4}"
  mode="${6:-default}"
  backup="${CONF_FILE}.bak.$$"

  cp "$CONF_FILE" "$backup"
  chmod 600 "$backup"
  write_config_for_major "$major" "$port" "$psk" "$ipv6" "$dns_pref" "$mode"

  if service_exists && binary_exists; then
    if ! start_or_restart; then
      warn "New configuration failed; restoring the previous configuration."
      mv "$backup" "$CONF_FILE"
      chmod 600 "$CONF_FILE"
      start_or_restart || true
      die "Configuration change was rolled back. Check: tail -n 100 ${LOG_FILE}"
    fi
  else
    warn "Configuration updated, but the Snell service is not installed."
  fi
  rm -f "$backup"
}

change_port() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  validate_snell_major "$major" || die "Cannot determine installed Snell version."
  port="$1"
  validate_port "$port" || die "Port must be an integer from 1 to 65535."
  old_port="$(current_port 2>/dev/null || true)"
  if [ "$port" != "$old_port" ] && port_in_use_for_major "$port" "$major"; then
    if [ "$major" = "5" ]; then
      die "TCP or UDP port ${port} is already in use."
    fi
    die "TCP port ${port} is already in use."
  fi

  ipv6="$(current_ipv6_enabled)"
  psk="$(conf_get psk)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  apply_config_change "$major" "$port" "$psk" "$ipv6" "$dns_pref" "$mode"
  if [ "$major" = "5" ] && shadowtls_enabled; then
    refresh_shadowtls_service_if_enabled
  fi
  log "Port changed: ${old_port:-unknown} -> ${port}."
  if [ "$major" = "5" ]; then
    if shadowtls_enabled; then
      warn "This changed the private Snell backend port. Clients continue using ShadowTLS TCP/$(current_shadowtls_port)."
    else
      warn "Remember to allow both TCP/${port} and UDP/${port} for Snell v5 QUIC Proxy Mode."
    fi
  fi
  show_config
}

change_psk() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  validate_snell_major "$major" || die "Cannot determine installed Snell version."
  new_psk="${1:-}"
  [ -n "$new_psk" ] || new_psk="$(random_psk)"
  [ -n "$new_psk" ] || die "PSK cannot be empty."

  port="$(current_port)"
  ipv6="$(current_ipv6_enabled)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  apply_config_change "$major" "$port" "$new_psk" "$ipv6" "$dns_pref" "$mode"
  log "PSK has been reset."
  show_config
}

change_mode() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  [ "$major" = "6" ] || die "The mode option is Snell v6 only. Snell v5 does not use v6 transport modes."
  mode="$1"
  if validate_mode "$mode"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      die "unsafe-raw disables encryption. Re-run with ALLOW_UNSAFE_RAW=1 if this is intentional."
    fi
    die "Invalid mode: ${mode}"
  fi

  port="$(current_port)"
  ipv6="$(current_ipv6_enabled)"
  psk="$(conf_get psk)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  apply_config_change 6 "$port" "$psk" "$ipv6" "$dns_pref" "$mode"
  log "Mode changed to ${mode}."
  show_config
}

change_dns() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  [ "$major" = "6" ] || die "dns-ip-preference is a Snell v6 server option. For v5, use the Alpine local DNS menu/command."
  dns_pref="$1"
  validate_dns "$dns_pref" || die "Invalid DNS preference: ${dns_pref}"

  port="$(current_port)"
  ipv6="$(current_ipv6_enabled)"
  psk="$(conf_get psk)"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  apply_config_change 6 "$port" "$psk" "$ipv6" "$dns_pref" "$mode"
  log "DNS preference changed to ${dns_pref}."
  show_config
}

toggle_ipv6() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  validate_snell_major "$major" || die "Cannot determine installed Snell version."
  state="$1"
  case "$state" in
    on|1|enable|enabled) ipv6=1 ;;
    off|0|disable|disabled) ipv6=0 ;;
    *) die "Use: ipv6 on|off" ;;
  esac

  port="$(current_port)" || die "Could not parse the current listen port."
  psk="$(conf_get psk)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  apply_config_change "$major" "$port" "$psk" "$ipv6" "$dns_pref" "$mode"
  if [ "$major" = "5" ]; then
    if [ "$ipv6" = "1" ]; then
      log "Snell v5 outbound IPv6 support enabled."
    else
      log "Snell v5 outbound IPv6 support disabled."
    fi
  else
    if [ "$ipv6" = "1" ]; then
      log "Snell v6 IPv6 listening enabled."
    else
      log "Snell v6 IPv6 listening disabled."
    fi
  fi
  show_config
}

show_config() {
  require_config
  major="$(current_snell_major 2>/dev/null || true)"
  validate_snell_major "$major" || major="unknown"
  listen="$(conf_get listen)"
  psk="$(conf_get psk)"
  tfo="$(current_client_tfo)"
  port="$(current_port 2>/dev/null || true)"
  version="$(installed_version 2>/dev/null || true)"
  host="$(current_server_host)"
  [ -n "$host" ] || host="YOUR_SERVER_IP"
  client_host="$(format_client_host "$host")"
  system_dns="$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {if (out != "") out=out ", "; out=out $2} END {print out}' "$RESOLV_CONF" 2>/dev/null || true)"
  [ -n "$system_dns" ] || system_dns="none"

  if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
    svc_status="running"
  else
    svc_status="stopped"
  fi

  printf '\n%s\n' '========================================'
  printf ' Snell v%s status / configuration\n' "$major"
  printf '%s\n' '========================================'
  printf 'Alpine:       %s\n' "${ALPINE_VERSION:-$(cat /etc/alpine-release 2>/dev/null || printf unknown)}"
  printf 'Architecture: %s\n' "${SNELL_ARCH:-unknown}"
  printf 'Version:      %s\n' "${version:-unknown}"
  printf 'Service:      %s\n' "$svc_status"
  printf 'Listen:       %s\n' "$listen"
  printf 'PSK:          %s\n' "$psk"
  printf 'Server:       %s\n' "$host"
  printf 'Alpine DNS:   %s\n' "$system_dns"

  if [ "$major" = "6" ]; then
    dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'default')"
    mode="$(conf_get mode 2>/dev/null || printf 'default')"
    printf 'DNS pref:     %s\n' "$dns_pref"
    printf 'Mode:         %s\n' "$mode"
    if [ "$(current_ipv6_enabled)" = "1" ]; then
      printf '%s\n' 'IPv6 listen:  enabled'
    else
      printf '%s\n' 'IPv6 listen:  disabled'
    fi
  elif [ "$major" = "5" ]; then
    ipv6_value="$(conf_get ipv6 2>/dev/null || printf 'false')"
    printf 'IPv6 outbound:%s\n' " ${ipv6_value}"
    if shadowtls_enabled; then
      stls_port="$(current_shadowtls_port)"
      stls_sni="$(current_shadowtls_sni)"
      stls_release="$(state_get SHADOWTLS_RELEASE 2>/dev/null || true)"
      if rc-service "$SHADOWTLS_SERVICE" status >/dev/null 2>&1; then stls_status=running; else stls_status=stopped; fi
      printf 'ShadowTLS:    enabled (%s)\n' "$stls_status"
      printf 'TLS port:     %s/tcp\n' "$stls_port"
      printf 'TLS SNI:      %s\n' "$stls_sni"
      printf 'TLS release:  %s\n' "${stls_release:-unknown}"
      printf '%s\n' 'QUIC Proxy:   blocked (block-quic=true; ShadowTLS is TCP-only)'
      printf '%s\n' 'Normal UDP:   supported via Snell UDP-over-TCP'
    else
      printf '%s\n' 'ShadowTLS:    disabled'
      printf '%s\n' 'QUIC Proxy:   enabled by protocol (UDP same port required)'
    fi
  fi

  if [ "$tfo" = "1" ]; then
    printf '%s\n' 'Surge TFO:    enabled'
  else
    printf '%s\n' 'Surge TFO:    disabled'
  fi
  printf 'Config:       %s\n' "$CONF_FILE"
  printf 'Log:          %s\n' "$LOG_FILE"

  if [ -n "$port" ]; then
    printf '\nSurge configuration:\n'
    if [ "$major" = "5" ]; then
      if shadowtls_enabled; then
        stls_port="$(current_shadowtls_port)"
        stls_sni="$(current_shadowtls_sni)"
        stls_password="$(current_shadowtls_password)"
        # ShadowTLS is TCP-only, so Snell v5 QUIC Proxy Mode must be blocked.
        # Other UDP traffic remains supported by Snell v5 via UDP-over-TCP.
        printf 'Snell-v5-TLS = snell, %s, %s, psk=%s, version=5, reuse=true, block-quic=true' "$client_host" "$stls_port" "$psk"
        if [ "$tfo" = "1" ]; then printf '%s' ', tfo=true'; fi
        printf ', shadow-tls-password=%s, shadow-tls-sni=%s, shadow-tls-version=3\n' "$stls_password" "$stls_sni"
        printf 'Firewall: allow TCP/%s only. Raw Snell is bound to 127.0.0.1:%s; QUIC is blocked, normal UDP remains available through Snell UDP-over-TCP.\n' "$stls_port" "$port"
      else
        printf 'Snell-v5 = snell, %s, %s, psk=%s, version=5, block-quic=off' "$client_host" "$port" "$psk"
        if [ "$tfo" = "1" ]; then printf '%s' ', tfo=true'; fi
        printf '\n'
        printf 'Firewall: allow TCP/%s and UDP/%s for v5 QUIC Proxy Mode.\n' "$port" "$port"
      fi
    elif [ "$major" = "6" ]; then
      mode="$(conf_get mode 2>/dev/null || printf 'default')"
      printf 'Snell-v6 = snell, %s, %s, psk=%s, version=6' "$client_host" "$port" "$psk"
      if [ "$mode" != "default" ]; then printf ', mode=%s' "$mode"; fi
      if [ "$tfo" = "1" ]; then printf '%s' ', tfo=true'; fi
      printf '\n'
    fi
  fi
  printf '%s\n\n' '========================================'
}

service_action() {
  action="$1"
  service_exists || die "OpenRC service is not installed."
  case "$action" in
    start)
      rc-service "$SERVICE_NAME" start
      if shadowtls_enabled; then rc-service "$SHADOWTLS_SERVICE" start || true; fi
      ;;
    stop)
      if shadowtls_enabled; then rc-service "$SHADOWTLS_SERVICE" stop >/dev/null 2>&1 || true; fi
      rc-service "$SERVICE_NAME" stop
      ;;
    restart)
      rc-service "$SERVICE_NAME" restart
      if shadowtls_enabled; then rc-service "$SHADOWTLS_SERVICE" restart || true; fi
      ;;
    status)
      rc-service "$SERVICE_NAME" status
      if shadowtls_enabled; then rc-service "$SHADOWTLS_SERVICE" status || true; fi
      ;;
    *) die "Unsupported service action: ${action}" ;;
  esac
}

show_logs() {
  [ -f "$LOG_FILE" ] || die "Log file does not exist: ${LOG_FILE}"
  printf '%s\n' '--- Snell log ---'
  tail -n 100 "$LOG_FILE"
  if shadowtls_enabled && [ -f "$SHADOWTLS_LOG" ]; then
    printf '\n%s\n' '--- ShadowTLS log ---'
    tail -n 100 "$SHADOWTLS_LOG"
  fi
}

uninstall_snell() {
  assume_yes="${1:-}"
  if [ "$assume_yes" != "--yes" ]; then
    if [ -t 0 ]; then
      printf 'This will remove Snell, its service, configuration and log. Continue? [y/N]: '
      read -r answer
      case "$answer" in y|Y|yes|YES) ;; *) log "Cancelled."; return 0 ;; esac
    else
      die "Non-interactive uninstall requires --yes."
    fi
  fi

  stop_remove_shadowtls_service
  if service_exists; then
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
  fi
  if [ -f "$DNS_BACKUP_FILE" ]; then
    warn "Restoring the DNS configuration saved before Snell manager changed it."
    restore_system_dns || true
  fi
  rm -f "$INIT_FILE" "$BIN_FILE" "${BIN_FILE}.version" "$LOG_FILE" "$SHADOWTLS_BIN" "$SHADOWTLS_LOG"
  rm -rf "$CONF_DIR"
  log "Snell has been uninstalled."
}

print_help() {
  cat <<EOF_HELP
Snell v5/v6 manager for Alpine Linux (no hard version limit; optional ShadowTLS v3 for v5)

Usage:
  $0                       Interactive menu
  $0 install [5|6]         Install/repair Snell and optionally select v5 or v6
  $0 update                Update the currently installed Snell major version
  $0 show                  Show current configuration and Surge line
  $0 port <1-65535>        Change listen port
  $0 psk [new_psk]         Reset PSK (random if omitted)
  $0 mode <mode>           v6 only: default | unshaped | unsafe-raw
  $0 dns <preference>      v6 only: Snell DNS preference: default | prefer-ipv4 | prefer-ipv6 | ipv4-only | ipv6-only
  $0 host <IP-or-domain>   Save/change the public IP or domain used in Surge output
  $0 local-dns show        Show Alpine /etc/resolv.conf DNS servers
  $0 local-dns set <IP...> Set 1-3 Alpine system DNS server IPs
  $0 local-dns restore     Restore DNS backed up before the first change
  $0 ipv6 on|off           v6: inbound IPv6; v5: outbound IPv6
  $0 tfo on|off            Enable/disable Surge client TCP Fast Open output
  $0 shadowtls enable       v5 only: install/reconfigure ShadowTLS v3 frontend
  $0 shadowtls disable      v5 only: disable ShadowTLS and expose Snell directly
  $0 shadowtls update       Update ShadowTLS binary and restart it
  $0 shadowtls show         Show ShadowTLS details
  $0 start|stop|restart    Control service
  $0 status                Show OpenRC service status
  $0 logs                  Show last 100 log lines
  $0 uninstall [--yes]     Remove Snell completely
  $0 help                  Show this help

Install environment variables:
  SNELL_VERSION=5|6, PORT, PSK, MODE(v6), DNS_PREFERENCE(v6), ENABLE_IPV6, SERVER_HOST, LOCAL_DNS, CLIENT_TFO, SNELL_URL
  SHADOWTLS_ENABLE=0|1, SHADOWTLS_PORT, SHADOWTLS_SNI, SHADOWTLS_PASSWORD, SHADOWTLS_URL, SHADOWTLS_RELEASE_VERSION
EOF_HELP
}

pause_menu() {
  printf '\nPress Enter to continue...'
  read -r _unused || true
}

interactive_menu() {
  while :; do
    clear 2>/dev/null || true
    printf '%s\n' '========================================'
    printf ' Snell v5/v6 Manager - Alpine %s\n' "${ALPINE_VERSION:-unknown}"
    printf '%s\n' '========================================'
    if binary_exists; then
      ver="$(installed_version 2>/dev/null || true)"
      printf 'Installed: %s\n' "${ver:-yes}"
    else
      printf '%s\n' 'Installed: no'
    fi
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
      printf '%s\n' 'Service:   running'
    else
      printf '%s\n' 'Service:   stopped / not installed'
    fi
    printf '%s\n' '----------------------------------------'
    printf '%s\n' '1) Install / repair'
    printf '%s\n' '2) Update installed Snell version'
    printf '%s\n' '3) Show configuration'
    printf '%s\n' '4) Change server IP / domain'
    printf '%s\n' '5) Change port'
    printf '%s\n' '6) Reset PSK'
    printf '%s\n' '7) Change mode (v6 only)'
    printf '%s\n' '8) Change Snell DNS preference (v6 only)'
    printf '%s\n' '9) Set / restore Alpine local DNS'
    printf '%s\n' '10) Toggle Surge TCP Fast Open (TFO)'
    printf '%s\n' '11) ShadowTLS v3 management (v5 only)'
    printf '%s\n' '12) Toggle IPv6 support'
    printf '%s\n' '13) Restart service'
    printf '%s\n' '14) Show status'
    printf '%s\n' '15) Show logs'
    printf '%s\n' '16) Uninstall'
    printf '%s\n' '0) Exit'
    printf '%s\n' '========================================'
    printf 'Select: '
    read -r choice || return 0

    case "$choice" in
      1) install_snell; pause_menu ;;
      2) update_snell; pause_menu ;;
      3) show_config; pause_menu ;;
      4)
        printf 'Server IP or domain: '
        read -r new_host
        set_server_host "$new_host"
        show_config
        pause_menu
        ;;
      5)
        printf 'New port: '
        read -r new_port
        change_port "$new_port"
        pause_menu
        ;;
      6)
        printf 'New PSK (leave blank for random): '
        read -r new_psk
        change_psk "$new_psk"
        pause_menu
        ;;
      7)
        printf 'Mode [default/unshaped/unsafe-raw]: '
        read -r new_mode
        if [ "$new_mode" = "unsafe-raw" ]; then
          printf 'unsafe-raw disables encryption. Type UNSAFE to continue: '
          read -r ack
          if [ "$ack" = "UNSAFE" ]; then
            ALLOW_UNSAFE_RAW=1 change_mode "$new_mode"
          else
            warn "Cancelled."
          fi
        else
          change_mode "$new_mode"
        fi
        pause_menu
        ;;
      8)
        printf 'Snell DNS preference [default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only]: '
        read -r new_dns
        change_dns "$new_dns"
        pause_menu
        ;;
      9)
        show_system_dns
        printf 'Enter DNS IPs separated by spaces, or type restore (blank = cancel): '
        read -r dns_line
        case "$(trim_value "$dns_line")" in
          '') log "Cancelled." ;;
          restore|RESTORE) restore_system_dns ;;
          *)
            set -- $dns_line
            set_system_dns "$@"
            ;;
        esac
        pause_menu
        ;;
      10)
        if [ "$(current_client_tfo)" = "1" ]; then
          set_client_tfo off
        else
          set_client_tfo on
        fi
        if config_exists; then show_config; fi
        pause_menu
        ;;
      11) shadowtls_menu; pause_menu ;;
      12)
        if [ "$(current_ipv6_enabled 2>/dev/null || printf 0)" = "1" ]; then
          toggle_ipv6 off
        else
          toggle_ipv6 on
        fi
        pause_menu
        ;;
      13) service_action restart; if shadowtls_enabled; then start_or_restart_shadowtls || true; fi; pause_menu ;;
      14) service_action status || true; if shadowtls_enabled; then rc-service "$SHADOWTLS_SERVICE" status || true; fi; pause_menu ;;
      15) show_logs; if shadowtls_enabled && [ -f "$SHADOWTLS_LOG" ]; then printf '\n--- ShadowTLS log ---\n'; tail -n 100 "$SHADOWTLS_LOG"; fi; pause_menu ;;
      16) uninstall_snell; pause_menu ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause_menu ;;
    esac
  done
}

main() {
  require_root
  check_platform

  cmd="${1:-menu}"
  case "$cmd" in
    menu)
      [ -t 0 ] || { print_help; exit 1; }
      interactive_menu
      ;;
    install)
      if [ $# -ge 2 ]; then
        validate_snell_major "$2" || die "Usage: $0 install [5|6]"
        SNELL_VERSION="$2"
        export SNELL_VERSION
      fi
      install_snell
      ;;
    update)
      update_snell
      ;;
    show|config)
      show_config
      ;;
    port)
      [ $# -ge 2 ] || die "Usage: $0 port <1-65535>"
      change_port "$2"
      ;;
    psk)
      change_psk "${2:-}"
      ;;
    mode)
      [ $# -ge 2 ] || die "Usage: $0 mode default|unshaped|unsafe-raw"
      change_mode "$2"
      ;;
    dns)
      [ $# -ge 2 ] || die "Usage: $0 dns default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only"
      change_dns "$2"
      ;;
    host)
      [ $# -ge 2 ] || die "Usage: $0 host <server-ip-or-domain>"
      set_server_host "$2"
      if config_exists; then show_config; fi
      ;;
    local-dns)
      [ $# -ge 2 ] || die "Usage: $0 local-dns show|set <DNS-IP...>|restore"
      case "$2" in
        show) show_system_dns ;;
        set)
          [ $# -ge 3 ] || die "Usage: $0 local-dns set <DNS-IP...>"
          shift 2
          set_system_dns "$@"
          ;;
        restore) restore_system_dns ;;
        *) die "Usage: $0 local-dns show|set <DNS-IP...>|restore" ;;
      esac
      ;;
    ipv6)
      [ $# -ge 2 ] || die "Usage: $0 ipv6 on|off"
      toggle_ipv6 "$2"
      ;;
    tfo)
      [ $# -ge 2 ] || die "Usage: $0 tfo on|off"
      set_client_tfo "$2"
      if config_exists; then show_config; fi
      ;;
    shadowtls)
      [ $# -ge 2 ] || die "Usage: $0 shadowtls enable|disable|update|show"
      case "$2" in
        enable|configure|reconfigure) enable_shadowtls ;;
        disable|off) disable_shadowtls ;;
        update) update_shadowtls ;;
        show|status) show_shadowtls ;;
        *) die "Usage: $0 shadowtls enable|disable|update|show" ;;
      esac
      ;;
    start|stop|restart|status)
      service_action "$cmd"
      ;;
    logs)
      show_logs
      ;;
    uninstall)
      uninstall_snell "${2:-}"
      ;;
    help|-h|--help)
      print_help
      ;;
    *)
      print_help >&2
      exit 1
      ;;
  esac
}

main "$@"
