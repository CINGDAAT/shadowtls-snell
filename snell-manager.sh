#!/bin/sh
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#==============================================
#	System Required: Debian/Alpine
#	Description: Snell Server 管理脚本
#==============================================

snell_v5_version="5.0.1"
snell_v6_version="6.0.0rc2"
snell_dir="/etc/snell/"
snell_bin="/usr/local/bin/snell-server"
snell_conf="/etc/snell/config.conf"
snell_version_file="/etc/snell/ver.txt"

# ShadowTLS（作为 Snell 的 TCP 前置层）
shadowtls_dir="/etc/shadow-tls"
shadowtls_bin="/usr/local/bin/shadow-tls"
shadowtls_conf="/etc/shadow-tls/config.conf"
shadowtls_version_file="/etc/shadow-tls/ver.txt"

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m" && Yellow_font_prefix="\033[0;33m"
Info="${Green_font_prefix}✓${Font_color_suffix}"
Error="${Red_font_prefix}✗${Font_color_suffix}"
Tip="${Yellow_font_prefix}!${Font_color_suffix}"

# 简洁终端输出
clearScreen(){
    [ -n "${TERM:-}" ] && clear 2>/dev/null || true
}

readInput(){
    if [ -n "$1" ]; then
        printf '> %s' "$1"
    else
        printf '> '
    fi

    # 无交互输入时优雅退出，避免 EOF 触发菜单递归
    IFS= read -r REPLY || exit 0
}

simpleHeader(){
    clearScreen
    echo
    if [ -e "${snell_bin}" ] && [ -e "${snell_conf}" ]; then
        checkStatus
        local header_ver
        header_ver=$(sed 's/^v//' "${snell_version_file}" 2>/dev/null)
        [ -z "$header_ver" ] && header_ver=$(confVersion)
        printf 'server: v%s · %s\n' "$header_ver" "$status"
        if shadowTLSConfigured; then
            readShadowTLSConfig >/dev/null 2>&1 || true
            checkShadowTLSStatus
            printf 'shadowtls: v3 · %s · :%s\n' "$stls_status" "${stls_port:-?}"
        fi
    else
        echo 'server: not installed'
    fi
}

pauseMenu(){
    echo
    readInput "按回车返回主菜单"
    startMenu
}

# dash/ash 兼容的 echo（dash 原生 echo 不支持 -e/-n，统一走 printf %b）
# shellcheck disable=SC3037
echo() {
    local opt_n=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) opt_n=1; shift ;;
            -e) shift ;;
            *) break ;;
        esac
    done
    if [ -n "$opt_n" ]; then
        printf '%b' "$*"
    else
        printf '%b\n' "$*"
    fi
}

# 读取配置中的协议版本号（config.conf version = 6 -> 6）
confVersion(){
	awk -F '=' '
		$1 ~ /^[[:space:]]*version[[:space:]]*$/ {
			v=$2
			sub(/^[[:space:]]*/, "", v)
			sub(/[[:space:]]*$/, "", v)
			print v
			exit
		}
	' "${snell_conf}" 2>/dev/null
}

# 检查是否为 Root 用户
checkRoot(){
	[ "$(id -u)" != 0 ] && echo -e "${Error} 需要 ROOT 权限，请使用 sudo -i" && exit 1
}

# 检查系统类型
checkSys(){
	if [ -f /etc/alpine-release ]; then
		release="alpine"
	elif [ -f /etc/debian_version ]; then
		release="debian"
	else
		release="unsupported"
		echo -e "${Error} 不支持的系统！本脚本仅支持 Debian/Alpine。"
		exit 1
	fi
}

# 安装运行依赖（仅在缺少命令时更新软件源）
installDependencies(){
	if [ "${release}" = "alpine" ]; then
		apk add --no-cache curl unzip tzdata gcompat upx iproute2 >/dev/null 2>&1 || {
			echo -e "${Error} 依赖安装失败"
			return 1
		}
	elif [ "${release}" = "debian" ]; then
		local packages=""
		command -v curl >/dev/null 2>&1 || packages="$packages curl"
		command -v unzip >/dev/null 2>&1 || packages="$packages unzip"
		command -v ss >/dev/null 2>&1 || packages="$packages iproute2"
		[ -f /etc/ssl/certs/ca-certificates.crt ] || packages="$packages ca-certificates"
		if [ -n "$packages" ]; then
			apt-get update >/dev/null 2>&1 && apt-get install -y $packages >/dev/null 2>&1 || {
				echo -e "${Error} 依赖安装失败"
				return 1
			}
		fi
	fi
	return 0
}

# 检查系统架构
sysArch() {
    machine=$(uname -m)
    case "$machine" in
        i386|i686) arch="i386" ;;
        armv6l)
            arch="armv7l"
            echo -e "${Tip} 检测到 armv6 架构，官方无对应构建，将尝试 armv7l 版本（可能无法运行）"
            ;;
        armv7l|armv7*) arch="armv7l" ;;
        aarch64|armv8*) arch="aarch64" ;;
        x86_64|amd64) arch="amd64" ;;
        *)
            echo -e "${Error} 不支持的系统架构：${machine}"
            return 1
            ;;
    esac
}

# 检查 Snell 是否安装
checkInstalledStatus(){
	[ ! -e "${snell_bin}" ] && echo -e "${Error} Snell Server 没有安装，请检查！" && return 1
	return 0
}

# 服务控制（自动适配 systemd / OpenRC）
svc(){
	if command -v systemctl >/dev/null 2>&1; then
		systemctl "$1" snell-server >/dev/null 2>&1
	elif command -v rc-service >/dev/null 2>&1; then
		rc-service snell-server "$1" >/dev/null 2>&1
	elif command -v service >/dev/null 2>&1; then
		service snell-server "$1" >/dev/null 2>&1
	else
		return 1
	fi
}

# 检查 Snell 运行状态
checkStatus(){
    status="stopped"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active snell-server.service >/dev/null 2>&1 && status="running"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service snell-server status >/dev/null 2>&1 && status="running"
    elif command -v service >/dev/null 2>&1; then
        service snell-server status >/dev/null 2>&1 && status="running"
    else
        return 1
    fi
}

# 版本号比较函数（优先正式版）
compareVersions(){
    local version1="$1"
    local version2="$2"
    local base_version1 base_version2 suffix1 suffix2 num1 num2 first_suffix

    version1=$(printf '%s' "$version1" | sed 's/^v//')
    version2=$(printf '%s' "$version2" | sed 's/^v//')
    [ "$version1" = "$version2" ] && return 1

    base_version1=$(printf '%s' "$version1" | sed 's/[a-z].*//')
    base_version2=$(printf '%s' "$version2" | sed 's/[a-z].*//')

    case "$version1" in *[a-z]*) suffix1=${version1#"$base_version1"} ;; *) suffix1="" ;; esac
    case "$version2" in *[a-z]*) suffix2=${version2#"$base_version2"} ;; *) suffix2="" ;; esac

    # 正式版高于同基础版本的测试版
    if [ "$base_version1" = "$base_version2" ]; then
        [ -z "$suffix1" ] && [ -n "$suffix2" ] && return 0
        [ -n "$suffix1" ] && [ -z "$suffix2" ] && return 2

        num1=$(printf '%s' "$suffix1" | grep -oE '[0-9]+$')
        num2=$(printf '%s' "$suffix2" | grep -oE '[0-9]+$')
        [ -z "$num1" ] && num1=0
        [ -z "$num2" ] && num2=0
        [ "$num1" -lt "$num2" ] && return 2
        [ "$num1" -gt "$num2" ] && return 0
        [ "$suffix1" = "$suffix2" ] && return 1
        first_suffix=$(printf '%s\n' "$suffix1" "$suffix2" | LC_ALL=C sort | head -1)
        [ "$first_suffix" = "$suffix1" ] && return 2
        return 0
    fi

    if printf '%s\n' "$base_version1" "$base_version2" | sort -V | head -1 | grep -q "^${base_version1}$"; then
        return 2
    fi
    return 0
}

# 验证版本 URL 是否有效
validateVersionUrl(){
    getSnellDownloadUrl "$1" || return 1
    curl -fsSIL --proto '=https' --tlsv1.2 --max-time 10 "$snell_url" 2>/dev/null | grep -q '^HTTP/.* 200'
}

# 检查版本更新
checkVersionUpdate(){
    local current_ver installed_version bin_version script_version web_version
    update_available=false
    current_installed_version=""
    latest_available_version=""
    best_version=""

    if [ -e "${snell_bin}" ] && [ -e "${snell_conf}" ]; then
        current_ver=$(confVersion)

        # 除 Snell v6 版外的旧版本已停更，不再检查在线更新
        if [ "$current_ver" != "6" ]; then
            update_available=false
            return 0
        fi

        installed_version=""
        if [ -e "${snell_version_file}" ]; then
            installed_version=$(sed 's/^v//' "${snell_version_file}")
        fi

        # 尝试从二进制程序获取真实版本，兼容缺失或过期的 ver.txt
        if [ -x "${snell_bin}" ]; then
            if command -v timeout >/dev/null 2>&1; then
                for opt in --version -v --help; do
                    bin_version=$(timeout 1 "${snell_bin}" "$opt" 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9]*' | head -1)
                    [ -n "$bin_version" ] && break
                done
            else
                bin_version=$("${snell_bin}" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9]*' | head -1)
            fi

            if [ -n "$bin_version" ]; then
                installed_version="$bin_version"
                echo "v${installed_version}" > "${snell_version_file}"
            fi
        fi

        # 无法识别真实版本时，不执行在线更新，避免生成空版本号 URL
        if [ -z "$installed_version" ]; then
            current_installed_version="unknown"
            return 0
        fi

        current_installed_version="$installed_version"

            # 仅 v6 可在线更新（v5 走 updateV5toV6，已在函数开头返回）
            script_version=${snell_v6_version}
            web_version=$(getLatestVersionFromWeb "v6")

            # 优先使用脚本内置版本，除非网页版本更新
            best_version="$installed_version"

            # 首先比较脚本内置版本
            if [ -n "$script_version" ]; then
                compareVersions "$best_version" "$script_version"
                case $? in
                    2)  # best_version < script_version
                        # 验证脚本内置版本的 URL 是否有效
                        if validateVersionUrl "$script_version"; then
                            best_version="$script_version"
                        else
                            :
                        fi
                        ;;
                esac
            fi

            # 然后比较网页版本，只有当网页版本比当前最佳版本更新时才采用
            if [ -n "$web_version" ]; then
                compareVersions "$best_version" "$web_version"
                if [ $? -eq 2 ]; then  # best_version < web_version
                    # 验证网页版本的 URL 是否有效
                    if validateVersionUrl "$web_version"; then
                        best_version="$web_version"
                    else
                        :
                    fi
                fi
            fi

            latest_available_version="$best_version"

            # 如果最佳版本与当前安装版本不同，则有更新可用
            compareVersions "$installed_version" "$best_version"
            if [ $? -eq 2 ]; then
                update_available=true
            fi
    fi
}

# 获取 Snell 下载链接
getSnellDownloadUrl(){
	sysArch || return 1
	snell_url="https://dl.nssurge.com/snell/snell-server-v${1}-linux-${arch}.zip"
}

# 下载 zip 并安装（临时目录隔离，失败自动清理）
installFromZip(){
    local version=$1
    local version_type=$2
    local url=$3
    local tmp_dir zip_file

    tmp_dir=$(mktemp -d /tmp/snell-install.XXXXXX) || {
        echo -e "${Error} 无法创建临时目录"
        return 1
    }
    zip_file="${tmp_dir}/snell-server.zip"

    if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --retry-delay 1 --max-time 60 -o "${zip_file}" "${url}" >/dev/null 2>&1; then
        echo -e "${Error} Snell Server ${Yellow_font_prefix}${version_type}${Font_color_suffix} 下载失败！"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if ! unzip -oq "${zip_file}" -d "${tmp_dir}" >/dev/null 2>&1 || [ ! -f "${tmp_dir}/snell-server" ] || [ -L "${tmp_dir}/snell-server" ]; then
        echo -e "${Error} Snell Server ${Yellow_font_prefix}${version_type}${Font_color_suffix} 解压失败！"
        rm -rf "${tmp_dir}"
        return 1
    fi
    if ! chmod +x "${tmp_dir}/snell-server"; then
        echo -e "${Error} 无法设置 Snell Server 执行权限"
        rm -rf "${tmp_dir}"
        return 1
    fi

    # Alpine: 官方二进制带 UPX 壳，需解包后才能由 gcompat 加载
    if [ "${release}" = "alpine" ] && command -v upx >/dev/null 2>&1 \
        && strings "${tmp_dir}/snell-server" 2>/dev/null | grep -q "UPX!"; then
        if upx -d -o "${tmp_dir}/snell-server.unpacked" "${tmp_dir}/snell-server" >/dev/null 2>&1; then
            mv -f "${tmp_dir}/snell-server.unpacked" "${tmp_dir}/snell-server"
            chmod +x "${tmp_dir}/snell-server"
        else
            echo -e "${Error} Snell Server 解包失败"
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    mkdir -p "${snell_dir}" || {
        echo -e "${Error} 无法创建 Snell 配置目录"
        rm -rf "${tmp_dir}"
        return 1
    }
    if ! mv -f "${tmp_dir}/snell-server" "${snell_bin}"; then
        echo -e "${Error} 无法安装 Snell Server 主程序"
        rm -rf "${tmp_dir}"
        return 1
    fi
    if ! printf 'v%s\n' "${version}" > "${snell_version_file}"; then
        echo -e "${Error} 无法记录 Snell Server 版本"
        rm -rf "${tmp_dir}"
        return 1
    fi
    rm -rf "${tmp_dir}"
    return 0
}

# 通用下载并安装 Snell 函数
downloadSnell(){
	local version=$1
	local version_type=$2

	getSnellDownloadUrl "${version}" || return 1
	installFromZip "${version}" "${version_type}" "${snell_url}"
}

# 安装 Snell
installSnell() {
	# 已安装时提示先卸载
	if [ -e "${snell_bin}" ]; then
		echo -e "${Error} 检测到 Snell Server 已安装！"
		echo -e "${Tip} 如需重装，请先选择「卸载 Snell Server」"
		sleep 2
		startMenu
		return 1
	fi

	simpleHeader
	echo
	echo "安装版本"
	echo " 1) v5（${snell_v5_version}，稳定版）"
	echo " 2) v6（${snell_v6_version}，最新版）"
	readInput "选择 [1/2]（默认 1.v5）："
	ver_choice="$REPLY"
	[ -z "${ver_choice}" ] && ver_choice="1"
	case "${ver_choice}" in
		1) ver="5" ;;
		2) ver="6" ;;
		*)
			echo -e "${Error} 输入无效，仅支持 1 或 2"
			sleep 2
			startMenu
			return 1
			;;
	esac

	echo -e "${Tip} 即将安装 Snell v${ver}（默认配置，安装后可用「设置配置」调整）"
	readInput " 确认安装？(Y/n)（默认 y）: "
	confirm="$REPLY"
	[ -z "${confirm}" ] && confirm="y"
	if [ "$confirm" != Y ] && [ "$confirm" != y ]; then
		echo -e "${Info} 已取消安装"
		sleep 2
		startMenu
		return 0
	fi

	if [ "${ver}" = "5" ]; then
		installSnellCore 5
	else
		installSnellCore 6
	fi
}

# 配置服务
setupService(){
	if command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then
		if ! cat > /etc/systemd/system/snell-server.service <<'EOF'
[Unit]
Description=Snell Service
After=network.target
[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/usr/local/bin/snell-server -c /etc/snell/config.conf
[Install]
WantedBy=multi-user.target
EOF
		then
			echo -e "${Error} 无法创建 systemd 服务文件"
			return 1
		fi
		if ! systemctl daemon-reload >/dev/null 2>&1 || ! systemctl enable snell-server >/dev/null 2>&1; then
			echo -e "${Error} 无法注册 systemd 服务"
			return 1
		fi
	elif [ -d /etc/init.d ] && command -v rc-update >/dev/null 2>&1; then
		# Alpine/OpenRC：自定义 start/stop（gcompat 加载的进程名是 musl loader，
		# start-stop-daemon --exec 进程名校验会失败，故直接 pid 管理）
		cat > /etc/init.d/snell-server << 'EOF'
#!/sbin/openrc-run
name="snell-server"
description="Snell Server"
pidfile="/run/${RC_SVCNAME}.pid"
logfile="/var/log/snell-server.log"

is_snell_pid() {
    local pid="$1"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -r "/proc/${pid}/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q 'snell-server'
}

start() {
    ebegin "Starting ${name}"
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
            eend 0 "already running"
            return 0
        fi
        rm -f "$pidfile"
    fi
    setsid /usr/local/bin/snell-server -c /etc/snell/config.conf >>"$logfile" 2>&1 &
    pid=$!
    echo "$pid" > "$pidfile"
    sleep 1
    if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
        eend 0
    else
        rm -f "$pidfile"
        eend 1
        return 1
    fi
}

stop() {
    ebegin "Stopping ${name}"
    pid=""
    [ -f "$pidfile" ] && pid=$(cat "$pidfile" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
        kill "$pid" 2>/dev/null
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
            sleep 1
            i=$((i + 1))
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$pidfile"
    eend 0
}

status() {
    pid=""
    [ -f "$pidfile" ] && pid=$(cat "$pidfile" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null && is_snell_pid "$pid"; then
        ebegin "${name} is running (pid ${pid})"
        eend 0
        return 0
    fi
    ebegin "${name} is stopped"
    eend 1
}

depend() {
    need net
}
EOF
		if ! chmod +x /etc/init.d/snell-server || ! rc-update add snell-server default >/dev/null 2>&1; then
			echo -e "${Error} 无法注册 OpenRC 服务"
			return 1
		fi
	else
		echo -e "${Error} 未找到可用的服务管理器（systemd/OpenRC）"
		return 1
	fi
}

# ============================== ShadowTLS ==============================
# ShadowTLS 作为 Snell 的 TCP 前置层：公网 -> ShadowTLS -> 127.0.0.1:Snell
shadowTLSConfigured(){
    [ -x "${shadowtls_bin}" ] && [ -f "${shadowtls_conf}" ]
}

readShadowTLSConfig(){
    [ -f "${shadowtls_conf}" ] || return 1
    stls_port=""; stls_sni=""; stls_password=""; stls_strict="false"
    local key val
    while IFS='=' read -r key val; do
        case "$key" in
            port) stls_port="$val" ;;
            sni) stls_sni="$val" ;;
            password) stls_password="$val" ;;
            strict) stls_strict="$val" ;;
        esac
    done < "${shadowtls_conf}"
    [ -n "$stls_port" ] && [ -n "$stls_sni" ] && [ -n "$stls_password" ]
}

writeShadowTLSConfig(){
    mkdir -p "${shadowtls_dir}" || return 1
    local tmp_conf
    tmp_conf=$(mktemp "${shadowtls_conf}.tmp.XXXXXX") || return 1
    chmod 600 "$tmp_conf" || { rm -f "$tmp_conf"; return 1; }
    {
        printf 'port=%s\n' "$stls_port"
        printf 'sni=%s\n' "$stls_sni"
        printf 'password=%s\n' "$stls_password"
        printf 'strict=%s\n' "${stls_strict:-false}"
    } > "$tmp_conf" || { rm -f "$tmp_conf"; return 1; }
    mv -f "$tmp_conf" "${shadowtls_conf}" || return 1
    chmod 600 "${shadowtls_conf}" || return 1
}

shadowTLSArch(){
    case "$(uname -m)" in
        x86_64|amd64) stls_arch="x86_64-unknown-linux-musl" ;;
        aarch64|armv8*) stls_arch="aarch64-unknown-linux-musl" ;;
        armv7l|armv7*) stls_arch="armv7-unknown-linux-musleabihf" ;;
        armv6l|armv6*) stls_arch="arm-unknown-linux-musleabi" ;;
        *) echo -e "${Error} ShadowTLS 官方 Release 不支持当前架构：$(uname -m)"; return 1 ;;
    esac
}

installShadowTLSBinary(){
    shadowTLSArch || return 1
    local tmp_bin url detected_ver
    tmp_bin=$(mktemp /tmp/shadow-tls.XXXXXX) || return 1
    url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-${stls_arch}"
    echo -e "${Info} 下载 ShadowTLS 最新版（${stls_arch}）"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --retry-delay 1 --max-time 60 -o "$tmp_bin" "$url"; then
        rm -f "$tmp_bin"
        echo -e "${Error} ShadowTLS 下载失败"
        return 1
    fi
    chmod +x "$tmp_bin" || { rm -f "$tmp_bin"; return 1; }
    "$tmp_bin" --version >/dev/null 2>&1 || { rm -f "$tmp_bin"; echo -e "${Error} ShadowTLS 二进制校验失败"; return 1; }
    mkdir -p "${shadowtls_dir}" || { rm -f "$tmp_bin"; return 1; }
    mv -f "$tmp_bin" "${shadowtls_bin}" || return 1
    chmod +x "${shadowtls_bin}" || return 1
    detected_ver=$("${shadowtls_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$detected_ver" ] && printf 'v%s\n' "$detected_ver" > "${shadowtls_version_file}"
}

shadowSvc(){
    if command -v systemctl >/dev/null 2>&1; then
        systemctl "$1" shadow-tls >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service shadow-tls "$1" >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
        service shadow-tls "$1" >/dev/null 2>&1
    else
        return 1
    fi
}

checkShadowTLSStatus(){
    stls_status="stopped"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active shadow-tls.service >/dev/null 2>&1 && stls_status="running"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service shadow-tls status >/dev/null 2>&1 && stls_status="running"
    elif command -v service >/dev/null 2>&1; then
        service shadow-tls status >/dev/null 2>&1 && stls_status="running"
    fi
}

setupShadowTLSService(){
    shadowTLSConfigured || return 1
    readShadowTLSConfig || return 1
    readConfig || return 1
    local extra="--v3"
    [ "$stls_strict" = "true" ] && extra="--v3 --strict"

    if command -v systemctl >/dev/null 2>&1 && systemctl show --property=Version >/dev/null 2>&1; then
        cat > /etc/systemd/system/shadow-tls.service <<EOF_UNIT
[Unit]
Description=ShadowTLS for Snell
After=network.target snell-server.service
Requires=snell-server.service

[Service]
Type=simple
User=root
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3s
ExecStart=${shadowtls_bin} server --listen [::]:${stls_port} --server 127.0.0.1:${port} --tls ${stls_sni}:443 --password ${stls_password} ${extra}

[Install]
WantedBy=multi-user.target
EOF_UNIT
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl enable shadow-tls >/dev/null 2>&1 || return 1
    elif [ -d /etc/init.d ] && command -v rc-update >/dev/null 2>&1; then
        {
            echo '#!/sbin/openrc-run'
            echo 'name="shadow-tls"'
            echo 'description="ShadowTLS for Snell"'
            printf 'command="%s"\n' "$shadowtls_bin"
            printf 'command_args="server --listen [::]:%s --server 127.0.0.1:%s --tls %s:443 --password %s %s"\n' "$stls_port" "$port" "$stls_sni" "$stls_password" "$extra"
            echo 'command_background="yes"'
            echo 'pidfile="/run/${RC_SVCNAME}.pid"'
            echo 'output_log="/var/log/shadow-tls.log"'
            echo 'error_log="/var/log/shadow-tls.log"'
            echo 'depend() {'
            echo '    need net snell-server'
            echo '}'
        } > /etc/init.d/shadow-tls || return 1
        chmod +x /etc/init.d/shadow-tls || return 1
        rc-update add shadow-tls default >/dev/null 2>&1 || return 1
    else
        echo -e "${Error} 未找到可用的服务管理器（systemd/OpenRC）"
        return 1
    fi
}

removeShadowTLSArtifacts(){
    shadowSvc stop >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable shadow-tls >/dev/null 2>&1 || true
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update del shadow-tls default >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/shadow-tls.service /etc/init.d/shadow-tls
    rm -f "${shadowtls_bin}"
    rm -rf "${shadowtls_dir}"
    rm -f /run/shadow-tls.pid /var/log/shadow-tls.log
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

setShadowTLSPort(){
    local old_port="${stls_port:-}"
    while true; do
        local prompt="请输入 ShadowTLS 公网端口 [1-65535]（默认 443）："
        [ -n "$old_port" ] && prompt="请输入 ShadowTLS 公网端口 [1-65535]（当前 ${old_port}，回车保留）："
        readInput "$prompt"
        input_stls_port="$REPLY"
        [ -z "$input_stls_port" ] && input_stls_port="${old_port:-443}"
        if ! echo "$input_stls_port" | grep -qE '^[0-9]+$' || [ "$input_stls_port" -lt 1 ] || [ "$input_stls_port" -gt 65535 ]; then
            echo -e "${Error} 端口无效"
            continue
        fi
        [ "$input_stls_port" = "$port" ] && { echo -e "${Error} 不能与 Snell 内部端口 ${port} 相同"; continue; }
        if [ "$input_stls_port" != "$old_port" ] && ss -tln | grep -q ":$input_stls_port "; then
            echo -e "${Error} 端口 $input_stls_port 已被占用"
            continue
        fi
        stls_port="$input_stls_port"
        break
    done
}

setShadowTLSSNI(){
    local prompt="请输入 ShadowTLS 握手域名（默认 www.apple.com）："
    [ -n "${stls_sni:-}" ] && prompt="请输入 ShadowTLS 握手域名（当前 ${stls_sni}，回车保留）："
    while true; do
        readInput "$prompt"
        input_stls_sni="$REPLY"
        [ -z "$input_stls_sni" ] && input_stls_sni="${stls_sni:-www.apple.com}"
        case "$input_stls_sni" in
            *[!A-Za-z0-9.-]*|.*|*.) echo -e "${Error} 域名格式无效" ;;
            *) stls_sni="$input_stls_sni"; break ;;
        esac
    done
}

setShadowTLSPassword(){
    local prompt="请输入 ShadowTLS 密码（16-64 位，回车随机生成）："
    [ -n "${stls_password:-}" ] && prompt="请输入 ShadowTLS 密码（已设置，回车保留）："
    while true; do
        readInput "$prompt"
        input_stls_password="$REPLY"
        if [ -z "$input_stls_password" ] && [ -n "${stls_password:-}" ]; then break; fi
        if [ -z "$input_stls_password" ]; then
            stls_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
            break
        fi
        if [ ${#input_stls_password} -lt 16 ] || [ ${#input_stls_password} -gt 64 ]; then
            echo -e "${Error} 密码长度必须为 16-64 位"; continue
        fi
        case "$input_stls_password" in
            *[!A-Za-z0-9._~-]*) echo -e "${Error} 仅支持 A-Z a-z 0-9 . _ ~ -" ;;
            *) stls_password="$input_stls_password"; break ;;
        esac
    done
}

setShadowTLSStrict(){
    echo "ShadowTLS v3 严格模式：1) 关闭（推荐）  2) 开启（仅 TLS 1.3）"
    local current="1"
    [ "${stls_strict:-false}" = "true" ] && current="2"
    while true; do
        readInput "选择 [1/2]（当前 ${current}，回车保留）："
        input_stls_strict="$REPLY"
        [ -z "$input_stls_strict" ] && input_stls_strict="$current"
        case "$input_stls_strict" in
            1) stls_strict="false"; break ;;
            2) stls_strict="true"; break ;;
            *) echo -e "${Error} 输入无效" ;;
        esac
    done
}

configureShadowTLSValues(){
    setShadowTLSPort
    setShadowTLSSNI
    setShadowTLSPassword
    setShadowTLSStrict
}

installShadowTLS(){
    checkInstalledStatus || return 1
    readConfig || return 1
    shadowTLSConfigured && { echo -e "${Tip} ShadowTLS 已安装"; sleep 2; return 0; }
    stls_port=""; stls_sni=""; stls_password=""; stls_strict="false"
    simpleHeader
    echo
    echo "安装 ShadowTLS v3"
    echo -e "${Tip} 启用后 Snell 仅监听 127.0.0.1:${port}"
    configureShadowTLSValues
    readInput "确认安装？(Y/n，默认 y)："
    confirm="$REPLY"; [ -z "$confirm" ] && confirm="y"
    [ "$confirm" = "n" ] || [ "$confirm" = "N" ] && return 0

    local old_listen="$listen_val" was_running=false
    checkStatus; [ "$status" = "running" ] && was_running=true
    installShadowTLSBinary || return 1
    writeShadowTLSConfig || { removeShadowTLSArtifacts; return 1; }
    listen_val="127.0.0.1:${port}"
    if ! writeConfig || ! setupShadowTLSService; then
        echo -e "${Error} 配置失败，正在回滚"
        removeShadowTLSArtifacts
        listen_val="$old_listen"; writeConfig >/dev/null 2>&1 || true
        return 1
    fi
    if [ "$was_running" = true ]; then
        svc restart >/dev/null 2>&1 || return 1
        waitServiceStart
        [ "$status" = "running" ] && shadowSvc start >/dev/null 2>&1 || true
    fi
    echo -e "${Info} ShadowTLS 安装完成"
    [ "$was_running" != true ] && echo -e "${Tip} Snell 原本为停止状态，ShadowTLS 保持停止"
    sleep 2
}

modifyShadowTLS(){
    shadowTLSConfigured || { echo -e "${Error} ShadowTLS 尚未安装"; sleep 2; return 1; }
    readConfig || return 1
    readShadowTLSConfig || return 1
    simpleHeader; echo; echo "修改 ShadowTLS 配置"
    configureShadowTLSValues
    writeShadowTLSConfig || return 1
    listen_val="127.0.0.1:${port}"; writeConfig || return 1
    setupShadowTLSService || return 1
    checkStatus
    if [ "$status" = "running" ]; then
        svc restart >/dev/null 2>&1 || true; waitServiceStart
        [ "$status" = "running" ] && shadowSvc restart >/dev/null 2>&1 || true
    fi
    echo -e "${Info} ShadowTLS 配置已更新"; sleep 2
}

updateShadowTLS(){
    shadowTLSConfigured || { echo -e "${Error} ShadowTLS 尚未安装"; sleep 2; return 1; }
    local old_ver new_ver was_running=false
    old_ver=$("${shadowtls_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    checkShadowTLSStatus; [ "$stls_status" = "running" ] && was_running=true
    installShadowTLSBinary || return 1
    new_ver=$("${shadowtls_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ "$was_running" = true ] && shadowSvc restart >/dev/null 2>&1 || true
    [ "$old_ver" = "$new_ver" ] && echo -e "${Info} 已是最新版本：v${new_ver}" || echo -e "${Info} 已更新：v${old_ver:-?} → v${new_ver:-?}"
    sleep 2
}

uninstallShadowTLS(){
    shadowTLSConfigured || { echo -e "${Tip} ShadowTLS 尚未安装"; sleep 2; return 0; }
    readInput "确认卸载 ShadowTLS 并恢复 Snell 公网直连？(y/N)："
    confirm="$REPLY"; [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || return 0
    readConfig || return 1
    local was_running=false
    checkStatus; [ "$status" = "running" ] && was_running=true
    removeShadowTLSArtifacts
    listen_val="::0:${port}"; writeConfig || return 1
    if [ "$was_running" = true ]; then svc restart >/dev/null 2>&1 || true; waitServiceStart; fi
    echo -e "${Info} ShadowTLS 已卸载，Snell 已恢复直接监听"; sleep 2
}

viewShadowTLSStatus(){
    shadowTLSConfigured || { echo -e "${Error} ShadowTLS 尚未安装"; sleep 2; return 1; }
    readConfig || return 1; readShadowTLSConfig || return 1; checkShadowTLSStatus
    local full_ver
    full_ver=$("${shadowtls_bin}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    simpleHeader; echo
    echo "ShadowTLS"
    echo "版本      : v${full_ver:-?} / 协议 v3"
    echo "服务状态  : ${stls_status}"
    echo "公网端口  : ${stls_port}"
    echo "Snell 后端: 127.0.0.1:${port}"
    echo "握手 SNI  : ${stls_sni}"
    echo "严格模式  : ${stls_strict}"
    pauseMenu
}

shadowTLSMenu(){
    while true; do
        simpleHeader; echo; echo "ShadowTLS 管理"
        if shadowTLSConfigured; then
            echo " 1) 修改配置    2) 查看状态"
            echo " 3) 更新程序    4) 卸载 ShadowTLS"
        else
            echo " 1) 安装 ShadowTLS v3"
        fi
        echo " 0) 返回主菜单"; echo
        readInput ""; stls_choice="$REPLY"
        case "$stls_choice" in
            0|'') return 0 ;;
            1) if shadowTLSConfigured; then modifyShadowTLS; else installShadowTLS; fi ;;
            2) viewShadowTLSStatus ;;
            3) updateShadowTLS ;;
            4) uninstallShadowTLS ;;
            *) echo -e "${Error} 输入无效"; sleep 2 ;;
        esac
    done
}

# 针对 Snell v6 检查密钥长度
checkPskForV6(){
    if [ ${#psk} -lt 16 ] || [ ${#psk} -gt 255 ]; then
        echo -e "${Error} 当前密钥长度为 ${#psk}，不符合 Snell v6 要求（16-255 位）"
        echo -e "请选择处理方式："
        echo -e "   1. 自动生成安全的随机长密钥（推荐）"
        echo -e "   2. 手动输入新的长密钥"
        while true; do
            readInput " 请选择 [1/2]（默认 1）: "
            psk_choice="$REPLY"
            [ -z "${psk_choice}" ] && psk_choice="1"
            case "$psk_choice" in
                1) psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
                   echo -e "${Info} 已自动生成新密钥: ${Green_font_prefix}${psk}${Font_color_suffix}"
                   break ;;
                2)
                   while true; do
                       readInput " 请输入新的密钥 [16-255 位]: "
                       new_psk="$REPLY"
                       if [ ${#new_psk} -ge 16 ] && [ ${#new_psk} -le 255 ]; then
                           psk=$new_psk
                           break
                       else
                           echo -e "${Error} 密钥长度必须在 16 到 255 位之间！"
                       fi
                   done
                   break ;;
                *) echo -e "${Error} 输入无效，仅支持 1 或 2" ;;
            esac
        done
    fi
}

# 设置项回显框
showSettingResult(){
    echo
    echo "$1"
    echo
}

# 写入配置文件
writeConfig(){
    mkdir -p "${snell_dir}" || {
        echo -e "${Error} 无法创建 Snell 配置目录"
        return 1
    }
    local tmp_conf
    tmp_conf=$(mktemp "${snell_conf}.tmp.XXXXXX") || {
        echo -e "${Error} 无法创建临时配置文件"
        return 1
    }
    chmod 600 "${tmp_conf}" || {
        rm -f "${tmp_conf}"
        echo -e "${Error} 无法保护临时配置文件"
        return 1
    }

    # 生成主配置（使用 printf 原样写入，避免转义用户输入）
    if ! {
        printf '%s\n' "[snell-server]"
        printf '%s\n' "listen = ${listen_val}"
        if [ "${ver}" != "6" ]; then
            printf '%s\n' "ipv6 = ${ipv6}"
        else
            printf '%s\n' "# ipv6 = ${ipv6}"
        fi
        printf '%s\n' "psk = ${psk}"
        if [ "${ver}" != "6" ]; then
            printf '%s\n' "obfs = ${obfs}"
        else
            printf '%s\n' "# obfs = ${obfs}"
        fi
        if [ "${ver}" != "6" ] && [ "${obfs}" != "off" ]; then
            printf '%s\n' "obfs-host = ${host}"
        elif [ "${ver}" = "6" ] && [ "${obfs}" != "off" ]; then
            printf '%s\n' "# obfs-host = ${host}"
        fi
        printf '%s\n' "tfo = ${tfo}"
        if [ "${ver}" = "6" ]; then
            printf '%s\n' "dns-ip-preference = ${dns_ip_pref:-default}"
            printf '%s\n' "mode = ${mode:-default}"
        else
            [ -n "${dns_ip_pref}" ] && printf '%s\n' "# dns-ip-preference = ${dns_ip_pref}"
            [ -n "${mode}" ] && printf '%s\n' "# mode = ${mode}"
        fi
        [ -n "${egress_interface}" ] && printf '%s\n' "egress-interface = ${egress_interface}"
        printf '%s\n' "version = ${ver}"
    } > "${tmp_conf}"; then
        rm -f "${tmp_conf}"
        echo -e "${Error} 无法生成 Snell 配置"
        return 1
    fi

    # 保留未知的自定义配置项
    if [ -f "${snell_conf}" ]; then
        local custom_configs=$(awk -F '=' '{
            key = $1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key != "listen" && key != "ipv6" && key != "psk" && key != "obfs" && key != "obfs-host" && key != "tfo" && key != "dns-ip-preference" && key != "mode" && key != "version" && key != "egress-interface" && key != "[snell-server]" && $0 !~ /^[[:space:]]*#/) {
                if (NF > 0 && $0 !~ /^[[:space:]]*$/) {
                    print $0
                }
            }
        }' "${snell_conf}")

        if [ -n "${custom_configs}" ]; then
            printf '\n' >> "${tmp_conf}"
            printf '%s\n' "# Custom Configs" >> "${tmp_conf}"
            printf '%s\n' "${custom_configs}" >> "${tmp_conf}"
        fi
    fi

    if ! mv -f "${tmp_conf}" "${snell_conf}"; then
        rm -f "${tmp_conf}"
        echo -e "${Error} 无法替换 Snell 配置文件"
        return 1
    fi
    if ! chmod 600 "${snell_conf}"; then
        echo -e "${Error} 无法设置配置文件权限"
        return 1
    fi
    return 0
}

# 读取配置文件（单次 awk 解析全部字段，替代逐行 cat|grep|awk）
readConfig(){
	[ ! -e "${snell_conf}" ] && echo -e "${Error} Snell Server 配置文件不存在！" && return 1
	# 每次读取前重置字段，避免旧配置值污染当前配置
	listen_val=""
	port=""
	ipv6="false"
	psk=""
	obfs="off"
	host=""
	tfo="true"
	dns_ip_pref=""
	mode=""
	egress_interface=""
	local conf_tmp
	conf_tmp=$(mktemp /tmp/snell_config_parse.XXXXXX) || {
		echo -e "${Error} 无法创建配置解析临时文件"
		return 1
	}
	chmod 600 "$conf_tmp" || {
		rm -f "$conf_tmp"
		echo -e "${Error} 无法保护配置解析临时文件"
		return 1
	}
	# 只解析 [snell-server] 区块，跳过注释和其他区块
	if ! awk -F '=' '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*\[/ {
			in_snell = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/)
			next
		}
		!in_snell || NF < 2 { next }
		{
			key=$1
			value=$0
			sub(/^[^=]*=/, "", value)
			sub(/^[[:space:]]+/, "", key)
			sub(/[[:space:]]+$/, "", key)
			sub(/^[[:space:]]*/, "", value)
			sub(/[[:space:]]*$/, "", value)
			print key "=" value
		}
	' "${snell_conf}" > "$conf_tmp"; then
		rm -f "$conf_tmp"
		echo -e "${Error} 无法解析 Snell 配置文件"
		return 1
	fi

	local key val
	while IFS='=' read -r key val; do
		case "$key" in
			listen)
				listen_val="$val"
				port=$(printf '%s' "$val" | awk -F',' '{print $1}' | sed 's/.*://')
				;;
			ipv6) ipv6="$val" ;;
			psk) psk="$val" ;;
			obfs) obfs="$val" ;;
			obfs-host) host="$val" ;;
			tfo) tfo="$val" ;;
			version) ver="$val" ;;
			dns-ip-preference) dns_ip_pref="$val" ;;
			mode) mode="$val" ;;
			egress-interface) egress_interface="$val" ;;
		esac
	done < "$conf_tmp"
	rm -f "$conf_tmp"

	[ -z "$dns_ip_pref" ] && [ "$ver" = "6" ] && dns_ip_pref="default"
	[ -z "$mode" ] && [ "$ver" = "6" ] && mode="default"
	return 0
}

# 设置端口
setPort(){
    local orig_port="$port"
    echo -e "${Tip} 请手动放行防火墙端口（脚本不操作系统防火墙）"
    while true; do
        local p_prompt="请输入端口 [1-65535]（默认 8443）："
        [ -n "$port" ] && p_prompt="请输入端口 [1-65535]（当前 ${port}，回车保留）："
        readInput "$p_prompt"
        input_port="$REPLY"
        [ -z "${input_port}" ] && input_port="${port:-8443}"
        if ! echo "$input_port" | grep -qE '^[0-9]+$' || [ "$input_port" -lt 1 ] || [ "$input_port" -gt 65535 ]; then
            echo -e "${Error} 端口无效，请输入 1-65535 之间的数字"

            continue
        fi
        port=$input_port
        if shadowTLSConfigured; then
            readShadowTLSConfig >/dev/null 2>&1 || true
            if [ -n "${stls_port:-}" ] && [ "$port" = "$stls_port" ]; then
                echo -e "${Error} Snell 内部端口不能与 ShadowTLS 公网端口 ${stls_port} 相同"
                port="$orig_port"
                continue
            fi
            listen_val="127.0.0.1:${port}"
        else
            # v5/v6 均使用 ::0:port 双栈简写（实测 v6 兼容该格式）
            listen_val="::0:${port}"
        fi
        if [ "$port" != "$orig_port" ] && ss -tuln | grep -q ":$port "; then
            echo -e "${Error} 端口 $port 已被占用，请选择其他端口"
        else
            showSettingResult "端口 : ${Red_background_prefix} ${port} ${Font_color_suffix}"
            break
        fi
    done
}

# 设置 IPv6
setIpv6(){
	echo
	echo "IPv6 解析"
	echo " 1) 开启"
	echo " 2) 关闭"
	local current_opt="2"
	[ "$ipv6" = "true" ] && current_opt="1"
	local p_prompt="选择 [1/2]（默认 2.关闭）："
	[ -n "$ipv6" ] && p_prompt="选择 [1/2]（当前 ${current_opt}，回车保留）："
	while true; do
		readInput "$p_prompt"
		input_ipv6="$REPLY"
		[ -z "${input_ipv6}" ] && input_ipv6="$current_opt"
		case "$input_ipv6" in
			1) ipv6=true; break ;;
			2) ipv6=false; break ;;
			*) echo -e "${Error} 输入无效，仅支持 1 或 2" ;;
		esac
	done
	showSettingResult "IPv6 解析 开启状态：${Red_background_prefix} ${ipv6} ${Font_color_suffix}"
}

# 设置密钥
setPSK(){
	echo "密钥设置（回车生成随机密钥；已有密钥回车保留）"
	local p_prompt="请输入密钥（回车随机生成）："
	[ -n "$psk" ] && p_prompt="请输入密钥（已有密钥，回车保留）："

	if [ "$ver" = "6" ]; then
	    echo -e "${Tip} Snell v6 密钥长度要求：16-255 位"
	    while true; do
	        readInput "$p_prompt"
	        input_psk="$REPLY"
	        if [ -z "${input_psk}" ] && [ -n "$psk" ]; then
	            break
	        elif [ -z "${input_psk}" ]; then
	            psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
	            break
	        elif [ ${#input_psk} -ge 16 ] && [ ${#input_psk} -le 255 ]; then
	            psk=$input_psk
	            break
	        else
	            echo -e "${Error} 密钥长度必须在 16 到 255 位之间"
	        fi
	    done
	else
	    readInput "$p_prompt"
	    input_psk="$REPLY"
	    if [ -z "${input_psk}" ] && [ -z "$psk" ]; then
	        psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
	    elif [ -n "${input_psk}" ]; then
	        psk=$input_psk
	    fi
	fi

	showSettingResult "密钥已设置"
}

# 设置 OBFS
setObfs(){
    echo
    echo "OBFS 设置"
    echo " 1) TLS"
    echo " 2) HTTP"
    echo " 3) 关闭"
    local current_opt="3"
    if [ "$obfs" = "tls" ]; then current_opt="1"; elif [ "$obfs" = "http" ]; then current_opt="2"; fi
    local p_prompt="选择 [1-3]（默认 3.关闭）："
    [ -n "$obfs" ] && p_prompt="选择 [1-3]（当前 ${current_opt}，回车保留）："
    while true; do
        readInput "$p_prompt"
        input_obfs="$REPLY"
        [ -z "${input_obfs}" ] && input_obfs="$current_opt"
        case "$input_obfs" in
            1|2|3) break ;;
            *) echo -e "${Error} 输入无效，仅支持 1、2 或 3" ;;
        esac
    done
    if [ "${input_obfs}" = "1" ]; then
        obfs="tls"
        setHost  # 强制设置 OBFS 域名
    elif [ "${input_obfs}" = "2" ]; then
        obfs="http"
        setHost  # 强制设置 OBFS 域名
    else
        obfs="off"
        host=""  # 清空 host
    fi
    local obfs_info="OBFS 状态：${Red_background_prefix} ${obfs} ${Font_color_suffix}"
    if [ "${obfs}" != "off" ]; then
        obfs_info="${obfs_info}\nOBFS 域名：${Red_background_prefix} ${host} ${Font_color_suffix}"
    fi
    showSettingResult "$obfs_info"
}

# 设置协议版本
setVer(){
	echo
	echo "协议版本"
	echo " 1) v5"
	echo " 2) v6"
	local current_opt="1"
	[ "$ver" = "6" ] && current_opt="2"
	local p_prompt="选择 [1/2]（默认 1.v5）："
	[ -n "$ver" ] && p_prompt="选择 [1/2]（当前 ${current_opt}，回车保留）："
	readInput "$p_prompt"
	input_ver="$REPLY"
	[ -z "${input_ver}" ] && input_ver="$current_opt"
	case "$input_ver" in
		1) ver="5" ;;
		2) ver="6" ;;
		*)
			echo -e "${Error} 输入无效，仅支持 1 或 2"
			return 1
			;;
	esac
	showSettingResult "Snell Server 协议版本：${Red_background_prefix} v${ver} ${Font_color_suffix}"
}

# 设置 OBFS 域名
setHost(){
	echo "请输入 Snell Server 域名，Snell v5 版本及以上如无特别需求可忽略。"
	local p_prompt="请输入域名（默认 www.wechat.com）："
	[ -n "$host" ] && p_prompt="请输入域名（当前 ${host}，回车保留）："
	while true; do
		readInput "$p_prompt"
		input_host="$REPLY"
		if [ -z "${input_host}" ]; then
			host="${host:-www.wechat.com}"
			break
		fi
		case "$input_host" in
			*[!A-Za-z0-9.-]*) echo -e "${Error} 域名格式无效，请勿包含空格或特殊字符" ;;
			*) host="$input_host"; break ;;
		esac
	done
	showSettingResult "域名 : ${Red_background_prefix} ${host} ${Font_color_suffix}"
}

# 设置 TCP Fast Open
setTFO(){
	echo
	echo "TCP Fast Open"
	echo " 1) 开启"
	echo " 2) 关闭"
	local current_opt="1"
	[ "$tfo" = "false" ] && current_opt="2"
	local p_prompt="选择 [1/2]（默认 1.开启）："
	[ -n "$tfo" ] && p_prompt="选择 [1/2]（当前 ${current_opt}，回车保留）："
	while true; do
		readInput "$p_prompt"
		input_tfo="$REPLY"
		[ -z "${input_tfo}" ] && input_tfo="$current_opt"
		case "$input_tfo" in
			1) tfo=true; break ;;
			2) tfo=false; break ;;
			*) echo -e "${Error} 输入无效，仅支持 1 或 2" ;;
		esac
	done
	showSettingResult "Snell TFO 开启状态：${Red_background_prefix} ${tfo} ${Font_color_suffix}"
}

# 设置 DNS IP 偏好 (Snell v6 专属)
setDNSIPPref(){
	echo
	echo "DNS IP 偏好"
	echo " 1) default"
	echo " 2) prefer-ipv4"
	echo " 3) prefer-ipv6"
	echo " 4) ipv4-only"
	echo " 5) ipv6-only"
	local current_opt="1"
	if [ "$dns_ip_pref" = "prefer-ipv4" ]; then current_opt="2"; elif [ "$dns_ip_pref" = "prefer-ipv6" ]; then current_opt="3"; elif [ "$dns_ip_pref" = "ipv4-only" ]; then current_opt="4"; elif [ "$dns_ip_pref" = "ipv6-only" ]; then current_opt="5"; fi
	local p_prompt="选择 [1-5]（默认 1.default）："
	[ -n "$dns_ip_pref" ] && p_prompt="选择 [1-5]（当前 ${current_opt}，回车保留）："
	while true; do
		readInput "$p_prompt"
		input_pref="$REPLY"
		[ -z "${input_pref}" ] && input_pref="$current_opt"
		case "$input_pref" in
			1) dns_ip_pref="default"; break ;;
			2) dns_ip_pref="prefer-ipv4"; break ;;
			3) dns_ip_pref="prefer-ipv6"; break ;;
			4) dns_ip_pref="ipv4-only"; break ;;
			5) dns_ip_pref="ipv6-only"; break ;;
			*) echo -e "${Error} 输入无效，仅支持 1 到 5" ;;
		esac
	done
	showSettingResult "DNS IP 偏好 状态：${Red_background_prefix} ${dns_ip_pref} ${Font_color_suffix}"
}

# 设置 模式 (Snell v6 专属)
setMode(){
	echo
	echo "混淆模式"
	echo " 1) default"
	echo " 2) unshaped"
	echo " 3) unsafe-raw"
	local current_opt="1"
	if [ "$mode" = "unshaped" ]; then current_opt="2"; elif [ "$mode" = "unsafe-raw" ]; then current_opt="3"; fi
	local p_prompt="选择 [1-3]（默认 1.default）："
	[ -n "$mode" ] && p_prompt="选择 [1-3]（当前 ${current_opt}，回车保留）："
	while true; do
		readInput "$p_prompt"
		input_pref="$REPLY"
		[ -z "${input_pref}" ] && input_pref="$current_opt"
		case "$input_pref" in
			1) mode="default"; break ;;
			2) mode="unshaped"; break ;;
			3) mode="unsafe-raw"; break ;;
			*) echo -e "${Error} 输入无效，仅支持 1、2 或 3" ;;
		esac
	done
	showSettingResult "混淆模式：${Red_background_prefix} ${mode} ${Font_color_suffix}"
}

# 选择目标版本（网页版优先并验证，否则用脚本内置版本）
pickVersion(){
    local new_ver=$1
    local script_version=""
    case "$new_ver" in
        "5") script_version=${snell_v5_version} ;;
        "6") script_version=${snell_v6_version} ;;
    esac

    local web_version=$(getLatestVersionFromWeb "v${new_ver}")
    if [ -n "$web_version" ] && validateVersionUrl "$web_version"; then
        # 网页版本比脚本内置版本旧时，回退脚本内置版本（避免装到历史版本）
        if [ -n "$script_version" ]; then
            compareVersions "$web_version" "$script_version"
            if [ $? -eq 2 ]; then
                echo "$script_version"
                return 0
            fi
        fi
        echo "$web_version"
        return 0
    fi
    [ -n "$script_version" ] && echo "$script_version"
    return 0
}

# 等待服务启动（最多 10 秒），结束后 $status 为 running/stopped
waitServiceStart(){
	local i=0
	while [ "$i" -lt 10 ]; do
		sleep 1
		checkStatus
		[ "$status" = "running" ] && break
		i=$((i+1))
	done
}

# 切换二进制版本（下载失败时原二进制未被替换，直接恢复服务）
switchBinary(){
    local old_version="$1"
    local new_version="$2"
    local target_full_version
    echo -e "${Info} 开始切换 Snell v${old_version} → v${new_version}"

    local was_running=false
    checkStatus
    [ "$status" = "running" ] && was_running=true
    if [ "$was_running" = true ] && ! svc stop; then
        echo -e "${Error} 无法停止当前 Snell Server，取消切换"
        return 1
    fi
    target_full_version=$(pickVersion "$new_version")

    if [ -n "$target_full_version" ] && downloadSnell "${target_full_version}" "Snell v${new_version} 版本"; then
        return 0
    fi

    echo -e "${Error} Snell v${new_version} 下载失败，保持当前版本"
    return 1
}

# 应用单项配置修改（读取配置 → 调用设置函数 → 写入 → 重启）
applyConfigChange(){
	local setter=$1
	simpleHeader
	if ! "$setter"; then
		echo -e "${Error} 配置项设置失败"
		sleep 2
		startMenu
		return 1
	fi
	if ! writeConfig; then
		sleep 2
		startMenu
		return 1
	fi
	restartSnell
}

# 修改配置
setConfig(){
    checkInstalledStatus || return 1
    local cver
    while true; do
        readConfig || break
        cver="$ver"
        simpleHeader
        echo
        echo "设置配置（当前 Snell v${cver}）"
        echo " 1) 设置监听端口"
        echo " 2) 设置密钥"
        if [ "$cver" != "6" ]; then
            echo " 3) 设置 OBFS"
            echo " 4) 设置 OBFS 域名"
            echo " 5) 设置 IPv6 解析"
        fi
        echo " 6) 设置 TCP Fast Open"
        echo " 7) 切换协议版本"
        if [ "$cver" = "6" ]; then
            echo " 8) 设置 DNS IP 偏好"
            echo " 9) 设置混淆模式"
        fi
        echo "10) 设置全部配置"
        echo
        readInput "按回车返回主菜单: "
        modify="$REPLY"
        [ -z "${modify}" ] && break

        case "$modify" in
            1) applyConfigChange setPort ;;
            2) applyConfigChange setPSK ;;
            3) applyConfigChange setObfs ;;  # setObfs 内已处理 host
            4)
                if [ "${obfs}" = "off" ]; then
                    echo -e "${Error} OBFS 当前为 off，无法设置 OBFS 域名。"
                    sleep 2
                    continue
                fi
                applyConfigChange setHost
                ;;
            5) applyConfigChange setIpv6 ;;
            6) applyConfigChange setTFO ;;
            7)
                if ! confirmVersionSwitch "$cver"; then
                    sleep 2
                    continue
                fi
                if [ "$ver" != "$cver" ]; then
                    applyVersionSwitch "$cver"
                else
                    if ! writeConfig; then
                        sleep 2
                        continue
                    fi
                    restartSnell
                fi
                ;;
            8)
                [ "$cver" != "6" ] && echo -e "${Error} 当前版本不是 Snell v6，不支持 DNS IP 偏好配置！" && sleep 2 && continue
                applyConfigChange setDNSIPPref
                ;;
            9)
                [ "$cver" != "6" ] && echo -e "${Error} 当前版本不是 Snell v6，不支持混淆模式配置！" && sleep 2 && continue
                applyConfigChange setMode
                ;;
            10)
                confirmVersionSwitch "$cver"

                setPort; setPSK
                [ "$ver" != "6" ] && setIpv6
                setTFO

                if [ "$ver" != "$cver" ]; then
                    # 版本专属配置由 applyVersionSwitch 统一询问，避免重复
                    applyVersionSwitch "$cver"
                else
                    if [ "$ver" = "6" ]; then
                        setDNSIPPref; setMode; checkPskForV6
                    else
                        setObfs
                    fi
                    if ! writeConfig; then
                        sleep 2
                        continue
                    fi
                    restartSnell
                fi
                ;;
            *)
                echo -e "${Error} 请输入正确数字${Yellow_font_prefix}[1-10]${Font_color_suffix}"
                sleep 2
                continue
                ;;
        esac
    done
    return 0
}

# 选择协议版本并确认切换（取消时恢复原版本，返回 1）
confirmVersionSwitch(){
    local current=$1
    setVer || { ver=$current; return 1; }
    [ "$ver" = "$current" ] && return 0
    if [ "$ver" -gt "$current" ]; then
        echo -e "${Info} 协议版本将从 Snell v${current} 升级到 Snell v${ver}"
        echo -e "确定要升级吗？(y/N)"
    else
        echo -e "${Info} 协议版本将从 Snell v${current} 降级到 Snell v${ver}"
        echo -e "确定要降级吗？(y/N)"
    fi
    readInput " 确认切换？（默认 n）: "
    confirm="$REPLY"
    [ -z "${confirm}" ] && confirm="n"
    if [ "$confirm" != Y ] && [ "$confirm" != y ]; then
        echo -e "${Info} 已取消切换，保持原版本"
        ver=$current
        return 1
    fi
    return 0
}

# 切换二进制版本并应用（成功/失败均进入主菜单）
applyVersionSwitch(){
    local current=$1
    local was_running=false
    checkStatus
    [ "$status" = "running" ] && was_running=true

    if [ "$ver" = "6" ]; then
        setDNSIPPref; setMode; checkPskForV6
    else
        setObfs
    fi

    if ! switchBinary "$current" "$ver"; then
        ver=$current
        if ! writeConfig; then
            echo -e "${Error} 无法恢复原版本配置"
            sleep 2
            startMenu
            return 1
        fi
        if [ "$was_running" = true ]; then
            restartSnell
        else
            echo -e "${Info} 已取消切换，服务保持停止状态"
        fi
        return
    fi

    if ! writeConfig; then
        echo -e "${Error} 新版本配置写入失败"
        sleep 2
        startMenu
        return 1
    fi

    if [ "$was_running" = true ]; then
        if ! svc restart; then
            status="stopped"
        else
            waitServiceStart
        fi
        if [ "$status" != "running" ]; then
            echo -e "${Error} 协议切换后服务启动失败，以下为错误日志："
            command -v journalctl >/dev/null 2>&1 && journalctl -u snell-server -n 20 --no-pager || rc-service snell-server status
        else
            echo -e "${Info} Snell Server 重启完毕！"
        fi
    else
        echo -e "${Info} 版本切换完成，服务保持停止状态"
    fi
    sleep 2
    startMenu
}
# 清理失败的安装残留
cleanupFailedInstall(){
    rm -f "${snell_bin}" /etc/systemd/system/snell-server.service /etc/init.d/snell-server
    rm -rf "${snell_dir}"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
}

# 安装 Snell 核心流程（按版本参数化配置项与下载源）
installSnellCore(){
	local v=$1
	local target_ver=""
	installDependencies || return 1
	setPort
	setPSK
	if [ "$v" = "6" ]; then
		setTFO
		setDNSIPPref
		setMode
	else
		setObfs
		setIpv6
		setTFO
	fi
	if [ "$v" = "6" ]; then
		target_ver=${snell_v6_version}
	else
		target_ver=${snell_v5_version}
	fi
	if ! downloadSnell "${target_ver}" "Snell v${v} 官网源版"; then
		cleanupFailedInstall
		sleep 2
		startMenu
		return 1
	fi
	if ! setupService || ! writeConfig; then
		echo -e "${Error} Snell Server 安装配置失败"
		cleanupFailedInstall
		sleep 2
		startMenu
		return 1
	fi
	startSnell || {
		startMenu
		return 1
	}
    viewConfig
}

# 启动 Snell
startSnell(){
    checkInstalledStatus || return 1
    checkStatus
    if [ "$status" = "running" ]; then
        return 0
    fi
    if ! svc start; then
        echo -e "${Error} Snell Server 启动命令失败"
        sleep 2
        return 1
    fi
    waitServiceStart

    if [ "$status" != "running" ]; then
        echo -e "${Error} Snell Server 启动失败"
        echo -e "${Tip} 请检查配置文件、端口占用和防火墙规则"
        command -v journalctl >/dev/null 2>&1 && journalctl -u snell-server -n 20 --no-pager || rc-service snell-server status
        sleep 2
        return 1
    fi
    if shadowTLSConfigured; then
        setupShadowTLSService >/dev/null 2>&1 || true
        shadowSvc start >/dev/null 2>&1 || shadowSvc restart >/dev/null 2>&1 || true
    fi
    return 0
}

# 停止 Snell
stopSnell(){
	checkInstalledStatus || return 1
	checkStatus
	if [ "$status" != "running" ]; then
		echo -e "${Error} Snell Server 没有运行，请检查！"
		sleep 2
		startMenu
		return 1
	fi
	shadowTLSConfigured && shadowSvc stop >/dev/null 2>&1 || true
	if ! svc stop; then
		echo -e "${Error} Snell Server 停止命令失败"
		sleep 2
		startMenu
		return 1
	fi
	echo -e "${Info} Snell Server 已停止"
    sleep 2
    startMenu
}

# 重启 Snell
restartSnell(){
	checkInstalledStatus || return 1
	if ! svc restart; then
		echo -e "${Error} Snell Server 重启命令失败"
		sleep 2
		startMenu
		return 1
	fi
	waitServiceStart
	if [ "$status" != "running" ]; then
		echo -e "${Error} Snell Server 重启后未运行"
		command -v journalctl >/dev/null 2>&1 && journalctl -u snell-server -n 20 --no-pager || rc-service snell-server status
	else
        if shadowTLSConfigured; then
            setupShadowTLSService >/dev/null 2>&1 || true
            shadowSvc restart >/dev/null 2>&1 || shadowSvc start >/dev/null 2>&1 || true
        fi
		echo -e "${Info} Snell Server 已重启"
	fi
    sleep 2
    startMenu
}

# Snell v5 更新到 Snell v6
updateV5toV6(){
	checkInstalledStatus || return 1
	readConfig || return 1

	if [ "$ver" != "5" ]; then
		echo -e "${Error} 当前版本不是 Snell v5，无法使用此功能！当前版本：Snell v${ver}"
		sleep 2
		startMenu
		return 1
	fi

	echo -e "${Tip} 即将将 Snell Server 从 ${Yellow_font_prefix}Snell v5${Font_color_suffix} 升级到 ${Green_font_prefix}Snell v6${Font_color_suffix}"
	echo -e "${Tip} 升级将保留现有端口/密钥配置，并新增 v6 专属设置（DNS IP 偏好、混淆模式）"
	readInput " 确认升级？(y/N)（默认 n）: "
	confirm="$REPLY"
	[ -z "${confirm}" ] && confirm="n"

	if [ "$confirm" != Y ] && [ "$confirm" != y ]; then
		startMenu
		return 0
	fi

	local was_running=false
	checkStatus
	[ "$status" = "running" ] && was_running=true
	if [ "$was_running" = true ] && ! svc stop; then
		echo -e "${Error} 无法停止当前 Snell Server，取消升级"
		sleep 2
		startMenu
		return 1
	fi

	target_v6_version=$(pickVersion "6")

	if [ -z "$target_v6_version" ]; then
		echo -e "${Error} 无法找到 Snell v6 下载版本"
		[ "$was_running" = true ] && svc start >/dev/null 2>&1
		sleep 2
		startMenu
		return 1
	fi

	if ! downloadSnell "${target_v6_version}" "Snell v6 版本"; then
		echo -e "${Error} Snell v6 下载失败，保持 Snell v5 版本"
		[ "$was_running" = true ] && svc start >/dev/null 2>&1
		sleep 2
		startMenu
		return 1
	fi
	actual_version=$(sed 's/^v//' "${snell_version_file}" 2>/dev/null)
	if ! echo "$actual_version" | grep -q '^6\.'; then
		echo -e "${Error} 下载结果不是 Snell v6，请重新安装"
		sleep 2
		startMenu
		return 1
	fi

	ver=6
	# listen 保持 ::0:port 双栈格式（v5/v6 通用），无需重建
	setDNSIPPref
	setMode
	checkPskForV6
	if ! writeConfig; then
		echo -e "${Error} v6 配置写入失败"
		sleep 2
		startMenu
		return 1
	fi

	if [ "$was_running" = true ]; then
		if ! svc start; then
			status="stopped"
		else
			waitServiceStart
		fi
		if [ "$status" != "running" ]; then
			echo -e "${Error} 升级后服务启动失败，以下为错误日志："
			command -v journalctl >/dev/null 2>&1 && journalctl -u snell-server -n 20 --no-pager || rc-service snell-server status
		else
			echo -e "${Info} Snell Server 已升级到 v6"
		fi
	else
		echo -e "${Info} Snell Server 已升级到 v6，服务保持停止状态"
	fi

	sleep 2
	startMenu
}
# 更新 Snell Server
updateSnellServer(){
    checkInstalledStatus || return 1
    readConfig || return 1
    checkVersionUpdate

    if [ "$update_available" != true ]; then
        if [ "$current_installed_version" = "unknown" ]; then
            echo -e "${Tip} 无法识别当前 Snell 版本，已跳过更新检查"
        elif [ -n "$current_installed_version" ]; then
            echo -e "${Info} 当前已是最新版本：v${current_installed_version}"
        else
            echo -e "${Info} 当前已是最新版本"
        fi
        sleep 2
        startMenu
        return 0
    fi

    echo -e "${Tip} 发现更新：v${current_installed_version} → v${latest_available_version}"
    readInput "确认更新？(Y/n，默认 y)："
    confirm="$REPLY"
    [ -z "$confirm" ] && confirm="y"
    case "$confirm" in
        [Nn]) startMenu; return 0 ;;
        [Yy]) ;;
        *) echo -e "${Error} 请输入 y 或 n"; sleep 2; startMenu; return 1 ;;
    esac

    local was_running=false
    checkStatus
    [ "$status" = "running" ] && was_running=true

    if [ "$was_running" = true ] && ! svc stop; then
        echo -e "${Error} 无法停止当前服务，取消更新"
        sleep 2
        startMenu
        return 1
    fi

    if ! downloadSnell "${latest_available_version}" "Snell v6 最新版"; then
        echo -e "${Error} 更新下载失败，已保留当前版本"
        [ "$was_running" = true ] && svc start >/dev/null 2>&1
        sleep 2
        startMenu
        return 1
    fi

    if [ "$was_running" != true ]; then
        echo -e "${Info} 更新完成，服务保持停止状态"
        sleep 2
        startMenu
        return 0
    fi

    if ! svc start; then
        status="stopped"
    else
        waitServiceStart
    fi

    if [ "$status" = "running" ]; then
        actual_version=$(sed 's/^v//' "${snell_version_file}")
        [ "$actual_version" != "$latest_available_version" ] && echo -e "${Tip} 当前运行版本：v${actual_version}"
    else
        echo -e "${Error} 更新后服务启动失败，以下为错误日志："
        command -v journalctl >/dev/null 2>&1 && journalctl -u snell-server -n 20 --no-pager || rc-service snell-server status
    fi

    sleep 2
    startMenu
}
# 自动获取 Snell 最新版本号（会话级缓存：一次脚本运行只抓取一次 release notes 页面）
# 收集页面中所有版本引用并取最大者，避免 head -1 命中历史版本引用
getLatestVersionFromWeb(){
    local version_type=$1
    local release_page="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"

    # 首次调用时抓取页面并缓存到会话变量
    if [ -z "$_snell_release_page" ]; then
        _snell_release_page=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 10 "$release_page" 2>/dev/null)
    fi

    local page_content="$_snell_release_page"
    if [ -z "$page_content" ]; then
        return 1
    fi

    local pattern
    if [ "$version_type" = "v5" ]; then
        pattern="snell-server-v5\.[0-9]+\.[0-9]+[a-z]*[0-9]*-linux"
    elif [ "$version_type" = "v6" ]; then
        pattern="snell-server-v6\.[0-9]+\.[0-9]+[a-z]*[0-9]*-linux"
    fi

    local best_ver=""
    local v
    for v in $(echo "$page_content" | grep -oE "$pattern" | sed 's/snell-server-v//g' | sed 's/-linux//g' | sort -u); do
        if [ -z "$best_ver" ]; then
            best_ver="$v"
        elif compareVersions "$v" "$best_ver"; then
            best_ver="$v"
        fi
    done
    if [ -n "$best_ver" ]; then
        echo "$best_ver"
        return 0
    fi

    return 1
}

# 卸载 Snell
uninstallSnell(){
	# 未安装时软提示回菜单（不直接退出）
	if [ ! -e "${snell_bin}" ]; then
		echo -e "${Error} Snell Server 没有安装！"
		sleep 2
		startMenu
		return 1
	fi

	local full_ver=$(sed 's/^v//' ${snell_version_file} 2>/dev/null)
	echo -e "${Error} 即将卸载 Snell Server："
	echo -e "  - 版本：${Yellow_font_prefix}v${full_ver:-?}${Font_color_suffix}"
	echo -e "  - 将移除：主程序、服务、配置文件（/etc/snell）"
	echo

	# 确认循环：非法输入重新询问
	while true; do
		readInput " 确认卸载？(y/N)（默认 n）: "
		unyn="$REPLY"
		[ -z "${unyn}" ] && unyn="n"
		case "$unyn" in
			[Yy]) break ;;
			[Nn]) echo && echo "卸载已取消" && sleep 2 && startMenu && return 0 ;;
			*) echo -e "${Error} 请输入 y 或 n" ;;
		esac
	done

	echo -e "${Info} 停止并禁用服务"
	checkStatus
	if [ "$status" = "running" ]; then
		if ! svc stop; then
			echo -e "${Error} 无法停止 Snell Server，取消卸载"
			sleep 2
			startMenu
			return 1
		fi
	fi
	if command -v systemctl >/dev/null 2>&1; then
		systemctl disable snell-server 2>/dev/null
	else
		rc-update del snell-server default 2>/dev/null
	fi

	# 服务脚本已按 PID 停止，兜底匹配 Snell 进程（含 musl loader 场景）
	pkill -f '[s]nell-server' 2>/dev/null

	if shadowTLSConfigured || [ -e "${shadowtls_bin}" ]; then
		echo -e "${Info} 同时移除 ShadowTLS"
		removeShadowTLSArtifacts
	fi

	echo -e "${Info} 移除主程序"
	rm -rf "${snell_bin}"

	echo -e "${Info} 移除服务文件"
	rm -f /etc/systemd/system/snell-server.service /etc/init.d/snell-server
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1

	echo -e "${Info} 移除配置文件及版本记录"
	rm -rf /etc/snell

	echo -e "${Info} 清理运行时文件"
	rm -f /run/snell-server.pid /var/log/snell-server.log

	echo && echo -e "${Green_font_prefix}Snell Server 卸载完成！${Font_color_suffix}" && echo
	sleep 2
    startMenu
}
# 获取 IPv4 地址（多源容错，串行最坏 15s）
getIpv4(){
	for src in https://ipinfo.io/ip https://api.ip.sb/ip https://members.3322.org/dyndns/getip; do
		ipv4=$(curl -fsSL4 --connect-timeout 2 --max-time 5 "$src" 2>/dev/null)
		[ -n "$ipv4" ] && return 0
	done
	ipv4="IPv4_Error"
}

# 获取 IPv6 地址
getIpv6(){
	ip6=$(curl -fsSL6 --connect-timeout 2 --max-time 5 https://ifconfig.co 2>/dev/null)
	[ -z "$ip6" ] && ip6="IPv6_Error"
}

# 查看配置信息
viewConfig(){
    checkInstalledStatus || return 1
    readConfig || return 1
    local ip_tmp_dir
    ip_tmp_dir=$(mktemp -d /tmp/snell-view.XXXXXX)
    if [ -n "$ip_tmp_dir" ]; then
        ( getIpv4; printf '%s\n' "$ipv4" > "${ip_tmp_dir}/ipv4" ) &
        ( getIpv6; printf '%s\n' "$ip6" > "${ip_tmp_dir}/ipv6" ) &
        wait
        ipv4=$(cat "${ip_tmp_dir}/ipv4" 2>/dev/null)
        ip6=$(cat "${ip_tmp_dir}/ipv6" 2>/dev/null)
        rm -rf "$ip_tmp_dir"
    else
        ipv4="IPv4_Error"
        ip6="IPv6_Error"
    fi

    simpleHeader
    echo
    echo "配置"
    if [ "${ipv4}" != "IPv4_Error" ]; then
        address="$ipv4"
    elif [ "${ip6}" != "IPv6_Error" ]; then
        address="[${ip6}]"
    else
        address="获取失败"
    fi
    echo "配置文件  : ${snell_conf}"
    echo "IPv4 地址 : ${address}"
    echo "端口      : ${port}"
    echo "密钥      : ${psk}"
    echo "版本      : v${ver}"
    echo "TFO       : ${tfo}"
    if [ "$ver" != "6" ]; then
        echo "OBFS      : ${obfs}"
        [ "$obfs" != "off" ] && [ -n "$host" ] && echo "域名      : ${host}"
        echo "IPv6      : ${ipv6}"
    else
        echo "DNS IP    : ${dns_ip_pref}"
        echo "模式      : ${mode}"
    fi
    [ -n "$egress_interface" ] && echo "出口网卡  : ${egress_interface}"
    if shadowTLSConfigured && readShadowTLSConfig; then
        echo "ShadowTLS : v3"
        echo "STLS 端口 : ${stls_port}"
        echo "STLS SNI  : ${stls_sni}"
    fi

    echo
    echo "Surge 配置："
    if [ "${ipv4}" != "IPv4_Error" ]; then
        printSurgeLine "$ipv4"
    elif [ "${ip6}" != "IPv6_Error" ]; then
        printSurgeLine "[${ip6}]"
    else
        echo -e "${Error} 无法获取 IP 地址！"
    fi
    pauseMenu
}

# 输出 Surge 客户端配置行（v6 带 mode 参数，v5+obfs 带 obfs 参数）
printSurgeLine(){
    local addr=$1
    local out_port="$port"
    local stls_extra=""
    if shadowTLSConfigured && readShadowTLSConfig; then
        out_port="$stls_port"
        stls_extra=", shadow-tls-password=${stls_password}, shadow-tls-version=3, shadow-tls-sni=${stls_sni}"
    fi
    if [ "${ver}" = "6" ]; then
        if [ -n "${mode}" ]; then
            echo "$(uname -n) = snell, ${addr}, ${out_port}, psk=${psk}, version=${ver}, mode=${mode}, reuse=true, tfo=${tfo}${stls_extra}"
        else
            echo "$(uname -n) = snell, ${addr}, ${out_port}, psk=${psk}, version=${ver}, reuse=true, tfo=${tfo}${stls_extra}"
        fi
    elif [ "${obfs}" != "off" ]; then
        echo "$(uname -n) = snell, ${addr}, ${out_port}, psk=${psk}, version=${ver}, obfs=${obfs}, obfs-host=${host}, reuse=true, tfo=${tfo}${stls_extra}"
    else
        echo "$(uname -n) = snell, ${addr}, ${out_port}, psk=${psk}, version=${ver}, reuse=true, tfo=${tfo}${stls_extra}"
    fi
}

# 查看运行状态
viewStatus(){
	checkInstalledStatus || return 1
	readConfig || return 1
	simpleHeader
	echo
	echo "状态"
	local full_ver=$(sed 's/^v//' "${snell_version_file}" 2>/dev/null)
	[ -z "$full_ver" ] && full_ver=$(confVersion)
	echo "版本      : v${full_ver}"
	echo "配置文件  : ${snell_conf}"
	echo "监听端口  : ${port}"

	checkStatus
	if [ "$status" = "running" ]; then
		echo "服务状态  : 运行中"
		local pid=""
		[ -f /run/snell-server.pid ] && pid=$(cat /run/snell-server.pid 2>/dev/null)
		[ -z "$pid" ] && pid=$(pgrep -f "snell-server -c" 2>/dev/null | head -1)
		[ -n "$pid" ] && echo "进程 PID  : ${pid}"
		local start_time
		start_time=$(ps -o lstart= -p "$pid" 2>/dev/null)
		[ -z "$start_time" ] && start_time=$(ps -o pid=,etime= 2>/dev/null | awk -v p="$pid" '$1==p{print $2}' | head -1)
		[ -n "$start_time" ] && echo "启动时间  : ${start_time}"
		if ss -tln | grep -q ":$port "; then
			echo "TCP   : 正常"
		else
			echo "TCP   : 异常"
		fi
		ss -uln | grep -q ":$port " && echo "UDP   : 正常"
        if shadowTLSConfigured && readShadowTLSConfig; then
            checkShadowTLSStatus
            echo "ShadowTLS : ${stls_status} (:${stls_port})"
        fi
	else
		echo "服务  : 未运行"
		ss -tuln | grep -q ":$port " && echo "端口  : 被其他程序占用"
	fi

	echo
	if command -v journalctl >/dev/null 2>&1; then
		echo "日志  : journalctl -u snell-server -n 50"
	else
		echo "日志  : tail -50 /var/log/snell-server.log"
	fi
	pauseMenu
}

# 主菜单
startMenu(){
    [ "${menu_active:-false}" = true ] && return 0
    menu_active=true
    while true; do
        simpleHeader
        echo
        echo ' 1) 安装服务    2) 启动服务'
        echo ' 3) 停止服务    4) 重启服务'
        echo ' 5) 设置配置    6) 查看配置'
        echo ' 7) 查看状态    8) 更新服务'
        echo ' 9) 卸载服务   10) ShadowTLS'
        echo ' 0) 退出脚本'
        echo
        readInput ""
        num="$REPLY"

        case "$num" in
            0) echo -e "${Info} 已退出脚本，再见！"; exit 0 ;;
            1) installSnell ;;
            2) startSnell ;;
            3) stopSnell ;;
            4) restartSnell ;;
            5) setConfig ;;
            6) viewConfig ;;
            7) viewStatus ;;
            8)
                if [ -e "${snell_bin}" ] && [ -e "${snell_conf}" ]; then
                    case "$(confVersion)" in
                        5) updateV5toV6 ;;
                        6) updateSnellServer ;;
                        *) echo -e "${Error} 配置文件版本未知，请检查 ${snell_conf}"; sleep 2 ;;
                    esac
                else
                    echo -e "${Error} 请先安装 Snell Server"
                    sleep 2
                fi
                ;;
            9) uninstallSnell ;;
            10) shadowTLSMenu ;;
            *)
                echo -e "${Error} 输入无效，请输入 0-10 之间的数字"
                sleep 2
                ;;
        esac
    done
}

# 启动前置检查（一次性执行，不随菜单循环重复）
checkRoot
checkSys
sysArch || exit 1

startMenu
