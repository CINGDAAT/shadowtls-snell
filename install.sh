#!/bin/sh
# BUILD_ID=20260817-1921-cachebust
set -eu

# GitHub quick bootstrap for Snell + ShadowTLS manager.
# Change this ONE value before publishing this file.
GITHUB_REPO="CINGDAAT/snell-manager"
GITHUB_BRANCH="main"
MANAGER_PATH="snell-manager-shadowtls-alpine.sh"

RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/${MANAGER_PATH}"

say() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "Linux only"

case "$GITHUB_REPO" in
    YOUR_GITHUB_USER/YOUR_REPO|*YOUR_GITHUB*)
        fail "Edit GITHUB_REPO in install.sh before publishing to GitHub"
        ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    fail "curl is required to run the GitHub bootstrap"
fi

# Alpine minimal installations may not have Bash, while the manager uses Bash.
if ! command -v bash >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        [ "$(id -u)" -eq 0 ] || fail "Run as root so Bash can be installed on Alpine"
        say "Installing Bash on Alpine..."
        apk add --no-cache bash ca-certificates curl >/dev/null
        update-ca-certificates >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
        [ "$(id -u)" -eq 0 ] || fail "Run as root so Bash can be installed"
        apt-get update -qq
        apt-get install -y bash ca-certificates curl >/dev/null
    else
        fail "Bash is required; install Bash first"
    fi
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT HUP INT TERM

say "Downloading Snell manager from GitHub..."
curl -fL --retry 3 --connect-timeout 10 -o "$TMP" "$RAW_URL"

bash -n "$TMP" || fail "Downloaded manager failed Bash syntax validation"
grep -q 'Snell + ShadowTLS Management Menu' "$TMP" || fail "Downloaded file does not look like the expected Snell manager"

[ "$#" -gt 0 ] || set -- install
say "Source: $RAW_URL"
SNELL_MANAGER_RAW_URL="$RAW_URL" bash "$TMP" "$@"
