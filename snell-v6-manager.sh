#!/bin/sh
set -eu

# Snell v6 manager for Alpine Linux 3.21-3.23
# POSIX /bin/sh compatible (BusyBox ash).
#
# Usage:
#   ./snell-v6-manager.sh                # interactive menu
#   ./snell-v6-manager.sh install
#   ./snell-v6-manager.sh update
#   ./snell-v6-manager.sh show
#   ./snell-v6-manager.sh port 6160
#   ./snell-v6-manager.sh psk [NEW_PSK]
#   ./snell-v6-manager.sh mode default|unshaped|unsafe-raw
#   ./snell-v6-manager.sh dns default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only
#   ./snell-v6-manager.sh ipv6 on|off
#   ./snell-v6-manager.sh restart|start|stop|status
#   ./snell-v6-manager.sh logs
#   ./snell-v6-manager.sh uninstall [--yes]
#
# Optional environment variables for install:
#   PORT=6160
#   PSK=your_psk
#   MODE=default|unshaped|unsafe-raw
#   DNS_PREFERENCE=default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only
#   ENABLE_IPV6=0|1
#   SERVER_HOST=1.2.3.4_or_domain
#   SNELL_URL=https://.../snell-server-v6...-linux-amd64.zip
#   ALLOW_UNSAFE_RAW=1

CONF_DIR="/etc/snell"
CONF_FILE="${CONF_DIR}/snell-server.conf"
BIN_FILE="/usr/local/bin/snell-server"
INIT_FILE="/etc/init.d/snell"
LOG_FILE="/var/log/snell.log"
SERVICE_NAME="snell"
RELEASE_PAGE="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"

log() { printf '%s\n' "[snell] $*"; }
warn() { printf '%s\n' "[snell] WARNING: $*" >&2; }
die() { printf '%s\n' "[snell] ERROR: $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root."
}

check_platform() {
  [ -f /etc/alpine-release ] || die "This script only supports Alpine Linux."
  ALPINE_VERSION="$(cat /etc/alpine-release)"
  ALPINE_MINOR="$(printf '%s' "$ALPINE_VERSION" | awk -F. '{print $1"."$2}')"
  case "$ALPINE_MINOR" in
    3.21|3.22|3.23) ;;
    *) die "Unsupported Alpine version: ${ALPINE_VERSION}. Only 3.21, 3.22 and 3.23 are supported." ;;
  esac

  case "$(uname -m)" in
    x86_64) SNELL_ARCH="amd64" ;;
    aarch64|arm64) SNELL_ARCH="aarch64" ;;
    i386|i486|i586|i686) SNELL_ARCH="i386" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

ensure_dependencies() {
  log "Installing/checking dependencies..."
  apk update
  apk add --no-cache ca-certificates curl unzip openssl gcompat iproute2
  update-ca-certificates >/dev/null 2>&1 || true
}

trim_value() {
  # Usage: trim_value "text"
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
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

port_in_use() {
  port="$1"
  ss -lnt 2>/dev/null | awk 'NR > 1 {print $4}' | grep -Eq "(^|[:.])${port}$"
}

random_port() {
  while :; do
    n="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
    port=$((10000 + n % 50001))
    if ! port_in_use "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
}

random_psk() {
  openssl rand -hex 16
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
  listen="$(conf_get listen 2>/dev/null || true)"
  case "$listen" in
    *'[::]:'*) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

current_port() {
  listen="$(conf_get listen 2>/dev/null || true)"
  port="$(printf '%s' "$listen" | sed -n 's/^0\.0\.0\.0:\([0-9][0-9]*\).*$/\1/p')"
  if [ -z "$port" ]; then
    port="$(printf '%s' "$listen" | sed -n 's/^\[::\]:\([0-9][0-9]*\).*$/\1/p')"
  fi
  [ -n "$port" ] || return 1
  printf '%s\n' "$port"
}

write_config() {
  listen="$1"
  psk="$2"
  dns_pref="$3"
  mode="$4"

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

create_initial_config() {
  if config_exists; then
    log "Existing configuration found; preserving ${CONF_FILE}."
    return 0
  fi

  port="${PORT:-}"
  [ -n "$port" ] || port="$(random_port)"
  validate_port "$port" || die "PORT must be an integer from 1 to 65535."

  psk="${PSK:-$(random_psk)}"
  [ -n "$psk" ] || die "PSK cannot be empty."

  mode="${MODE:-default}"
  if validate_mode "$mode"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      die "unsafe-raw disables encryption. Set ALLOW_UNSAFE_RAW=1 only if you intentionally want it."
    fi
    die "Invalid MODE: ${mode}"
  fi

  dns_pref="${DNS_PREFERENCE:-prefer-ipv4}"
  validate_dns "$dns_pref" || die "Invalid DNS_PREFERENCE: ${dns_pref}"

  ipv6="${ENABLE_IPV6:-0}"
  case "$ipv6" in 0|1) ;; *) die "ENABLE_IPV6 must be 0 or 1." ;; esac
  listen="$(listen_from_port_ipv6 "$port" "$ipv6")"

  write_config "$listen" "$psk" "$dns_pref" "$mode"
  log "Created ${CONF_FILE}."
}

resolve_download_url() {
  if [ -n "${SNELL_URL:-}" ]; then
    url="$SNELL_URL"
  else
    log "Resolving current Snell v6 download from Surge..." >&2
    page="$(curl -fsSL --retry 3 --connect-timeout 10 "$RELEASE_PAGE")" || die "Unable to fetch the official Snell release page."
    url="$(printf '%s\n' "$page" \
      | grep -Eo "https://dl\\.nssurge\\.com/snell/snell-server-v6[^[:space:]\"'<>)]*-linux-${SNELL_ARCH}\\.zip" \
      | tail -n 1 || true)"
    [ -n "$url" ] || die "Could not find a Snell v6 package for ${SNELL_ARCH}. Set SNELL_URL manually if Surge changed the release-page format."
  fi

  case "$url" in
    https://dl.nssurge.com/snell/*-linux-"${SNELL_ARCH}".zip) ;;
    *) die "Refusing unexpected download URL: ${url}" ;;
  esac
  printf '%s\n' "$url"
}

extract_version_from_url() {
  url="$1"
  basename "$url" | sed -n 's/^snell-server-\(v6[^-]*\)-linux-.*\.zip$/\1/p'
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
  url="$(resolve_download_url)"
  version="$(extract_version_from_url "$url")"
  [ -n "$version" ] || version="v6 (unknown build)"

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
    die "The Snell binary could not run through Alpine's gcompat layer."
  fi
  rm -rf "$tmp_dir"
  printf '%s\n' "$version" > "${destination}.version"
}

install_openrc_service() {
  touch "$LOG_FILE"
  cat > "$INIT_FILE" <<'EOF_INIT'
#!/sbin/openrc-run

name="Snell Server"
description="Snell v6 Proxy Server"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell/snell-server.conf"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
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
    printf '%s\n' "$out" | sed -n 's/.*\(v6\.[0-9][^[:space:]]*\).*/\1/p' | head -n 1
  fi
}

install_snell() {
  ensure_dependencies
  create_initial_config
  tmp_bin="${BIN_FILE}.new.$$"
  backup_bin="${BIN_FILE}.bak.$$"
  backup_ver="${BIN_FILE}.version.bak.$$"
  had_binary=0
  rm -f "$tmp_bin" "${tmp_bin}.version" "$backup_bin" "$backup_ver"
  download_binary_to "$tmp_bin"

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
  install_openrc_service

  if ! start_or_restart; then
    if [ "$had_binary" = "1" ]; then
      warn "New binary failed to start; restoring the previous binary."
      mv "$backup_bin" "$BIN_FILE"
      if [ -f "$backup_ver" ]; then
        mv "$backup_ver" "${BIN_FILE}.version"
      else
        rm -f "${BIN_FILE}.version"
      fi
      chmod 755 "$BIN_FILE"
      start_or_restart || true
      die "Install/repair failed and the previous binary was restored."
    fi
    die "Snell failed to start. Check: tail -n 100 ${LOG_FILE}"
  fi

  rm -f "$backup_bin" "$backup_ver"
  log "Installation completed."
  show_config
}

update_snell() {
  binary_exists || die "Snell is not installed. Run: $0 install"
  ensure_dependencies

  tmp_bin="${BIN_FILE}.new.$$"
  backup_bin="${BIN_FILE}.bak.$$"
  backup_ver="${BIN_FILE}.version.bak.$$"
  rm -f "$tmp_bin" "${tmp_bin}.version" "$backup_bin" "$backup_ver"

  download_binary_to "$tmp_bin"
  new_version="$(cat "${tmp_bin}.version" 2>/dev/null || true)"
  old_version="$(installed_version 2>/dev/null || true)"

  cp "$BIN_FILE" "$backup_bin"
  [ -f "${BIN_FILE}.version" ] && cp "${BIN_FILE}.version" "$backup_ver" || true

  mv "$tmp_bin" "$BIN_FILE"
  if [ -f "${tmp_bin}.version" ]; then
    mv "${tmp_bin}.version" "${BIN_FILE}.version"
  fi
  chmod 755 "$BIN_FILE"

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

  rm -f "$backup_bin" "$backup_ver"
  if [ -n "$old_version" ] && [ "$old_version" = "$new_version" ]; then
    log "Reinstalled ${new_version}; it was already the current resolved build."
  else
    log "Updated: ${old_version:-unknown} -> ${new_version:-unknown}."
  fi
}

require_config() {
  config_exists || die "Snell configuration not found. Run: $0 install"
}

apply_config_change() {
  listen="$1"
  psk="$2"
  dns_pref="$3"
  mode="$4"
  backup="${CONF_FILE}.bak.$$"

  cp "$CONF_FILE" "$backup"
  chmod 600 "$backup"
  write_config "$listen" "$psk" "$dns_pref" "$mode"

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
  port="$1"
  validate_port "$port" || die "Port must be an integer from 1 to 65535."
  old_port="$(current_port 2>/dev/null || true)"
  if [ "$port" != "$old_port" ] && port_in_use "$port"; then
    die "TCP port ${port} is already in use."
  fi

  ipv6="$(current_ipv6_enabled)"
  psk="$(conf_get psk)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  listen="$(listen_from_port_ipv6 "$port" "$ipv6")"
  apply_config_change "$listen" "$psk" "$dns_pref" "$mode"
  log "Port changed: ${old_port:-unknown} -> ${port}."
  show_config
}

change_psk() {
  require_config
  new_psk="${1:-}"
  [ -n "$new_psk" ] || new_psk="$(random_psk)"
  [ -n "$new_psk" ] || die "PSK cannot be empty."

  listen="$(conf_get listen)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  apply_config_change "$listen" "$new_psk" "$dns_pref" "$mode"
  log "PSK has been reset."
  show_config
}

change_mode() {
  require_config
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

  listen="$(conf_get listen)"
  psk="$(conf_get psk)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  apply_config_change "$listen" "$psk" "$dns_pref" "$mode"
  log "Mode changed to ${mode}."
  show_config
}

change_dns() {
  require_config
  dns_pref="$1"
  validate_dns "$dns_pref" || die "Invalid DNS preference: ${dns_pref}"

  listen="$(conf_get listen)"
  psk="$(conf_get psk)"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  apply_config_change "$listen" "$psk" "$dns_pref" "$mode"
  log "DNS preference changed to ${dns_pref}."
  show_config
}

toggle_ipv6() {
  require_config
  state="$1"
  case "$state" in
    on|1|enable|enabled) ipv6=1 ;;
    off|0|disable|disabled) ipv6=0 ;;
    *) die "Use: ipv6 on|off" ;;
  esac

  port="$(current_port)" || die "Could not parse the current listen port."
  listen="$(listen_from_port_ipv6 "$port" "$ipv6")"
  psk="$(conf_get psk)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'prefer-ipv4')"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  apply_config_change "$listen" "$psk" "$dns_pref" "$mode"
  if [ "$ipv6" = "1" ]; then
    log "IPv6 listening enabled."
  else
    log "IPv6 listening disabled."
  fi
  show_config
}

show_config() {
  require_config
  listen="$(conf_get listen)"
  psk="$(conf_get psk)"
  dns_pref="$(conf_get dns-ip-preference 2>/dev/null || printf 'default')"
  mode="$(conf_get mode 2>/dev/null || printf 'default')"
  port="$(current_port 2>/dev/null || true)"
  version="$(installed_version 2>/dev/null || true)"
  host="${SERVER_HOST:-YOUR_SERVER_IP}"

  if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
    svc_status="running"
  else
    svc_status="stopped"
  fi

  printf '\n%s\n' '========================================'
  printf '%s\n' ' Snell v6 status / configuration'
  printf '%s\n' '========================================'
  printf 'Alpine:       %s\n' "${ALPINE_VERSION:-$(cat /etc/alpine-release 2>/dev/null || printf unknown)}"
  printf 'Architecture: %s\n' "${SNELL_ARCH:-unknown}"
  printf 'Version:      %s\n' "${version:-unknown}"
  printf 'Service:      %s\n' "$svc_status"
  printf 'Listen:       %s\n' "$listen"
  printf 'PSK:          %s\n' "$psk"
  printf 'DNS:          %s\n' "$dns_pref"
  printf 'Mode:         %s\n' "$mode"
  printf 'Config:       %s\n' "$CONF_FILE"
  printf 'Log:          %s\n' "$LOG_FILE"
  if [ -n "$port" ]; then
    printf '\nSurge configuration:\n'
    printf 'Snell-v6 = snell, %s, %s, psk=%s, version=6' "$host" "$port" "$psk"
    if [ "$mode" != "default" ]; then
      printf ', mode=%s' "$mode"
    fi
    printf '\n'
  fi
  printf '%s\n\n' '========================================'
}

service_action() {
  action="$1"
  service_exists || die "OpenRC service is not installed."
  case "$action" in
    start|stop|restart|status) rc-service "$SERVICE_NAME" "$action" ;;
    *) die "Unsupported service action: ${action}" ;;
  esac
}

show_logs() {
  [ -f "$LOG_FILE" ] || die "Log file does not exist: ${LOG_FILE}"
  tail -n 100 "$LOG_FILE"
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

  if service_exists; then
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
  fi
  rm -f "$INIT_FILE" "$BIN_FILE" "${BIN_FILE}.version" "$LOG_FILE"
  rm -rf "$CONF_DIR"
  log "Snell has been uninstalled."
}

print_help() {
  cat <<EOF_HELP
Snell v6 manager for Alpine 3.21-3.23

Usage:
  $0                       Interactive menu
  $0 install               Install or repair Snell v6
  $0 update                Download the current official v6 build and restart
  $0 show                  Show current configuration and Surge line
  $0 port <1-65535>        Change listen port
  $0 psk [new_psk]         Reset PSK (random if omitted)
  $0 mode <mode>           default | unshaped | unsafe-raw
  $0 dns <preference>      default | prefer-ipv4 | prefer-ipv6 | ipv4-only | ipv6-only
  $0 ipv6 on|off           Enable/disable IPv6 listening
  $0 start|stop|restart    Control service
  $0 status                Show OpenRC service status
  $0 logs                  Show last 100 log lines
  $0 uninstall [--yes]     Remove Snell completely
  $0 help                  Show this help

Install environment variables:
  PORT, PSK, MODE, DNS_PREFERENCE, ENABLE_IPV6, SERVER_HOST, SNELL_URL
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
    printf '%s\n' ' Snell v6 Manager - Alpine 3.21-3.23'
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
    printf '%s\n' '2) Update Snell v6'
    printf '%s\n' '3) Show configuration'
    printf '%s\n' '4) Change port'
    printf '%s\n' '5) Reset PSK'
    printf '%s\n' '6) Change mode'
    printf '%s\n' '7) Change DNS preference'
    printf '%s\n' '8) Toggle IPv6 listening'
    printf '%s\n' '9) Restart service'
    printf '%s\n' '10) Show status'
    printf '%s\n' '11) Show logs'
    printf '%s\n' '12) Uninstall'
    printf '%s\n' '0) Exit'
    printf '%s\n' '========================================'
    printf 'Select: '
    read -r choice || return 0

    case "$choice" in
      1) install_snell; pause_menu ;;
      2) update_snell; pause_menu ;;
      3) show_config; pause_menu ;;
      4)
        printf 'New port: '
        read -r new_port
        change_port "$new_port"
        pause_menu
        ;;
      5)
        printf 'New PSK (leave blank for random): '
        read -r new_psk
        change_psk "$new_psk"
        pause_menu
        ;;
      6)
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
      7)
        printf 'DNS [default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only]: '
        read -r new_dns
        change_dns "$new_dns"
        pause_menu
        ;;
      8)
        if [ "$(current_ipv6_enabled 2>/dev/null || printf 0)" = "1" ]; then
          toggle_ipv6 off
        else
          toggle_ipv6 on
        fi
        pause_menu
        ;;
      9) service_action restart; pause_menu ;;
      10) service_action status || true; pause_menu ;;
      11) show_logs; pause_menu ;;
      12) uninstall_snell; pause_menu ;;
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
    ipv6)
      [ $# -ge 2 ] || die "Usage: $0 ipv6 on|off"
      toggle_ipv6 "$2"
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
