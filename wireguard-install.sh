#!/bin/bash

# WireGuard 节点一键安装脚本（Clash 配置直出版）
# 基于 angristan/wireguard-install 改造
# https://github.com/angristan/wireguard-install

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- 解析命令行参数 ----------
INTERACTIVE=0
DO_UNINSTALL=0
for arg in "$@"; do
	case "$arg" in
	--interactive) INTERACTIVE=1 ;;
	--uninstall) DO_UNINSTALL=1 ;;
	--help)
		echo "用法: bash $0 [选项]"
		echo ""
		echo "选项:"
		echo "  （无参数）      零交互装节点，自动生成 Clash 配置（默认）"
		echo "  --interactive   交互模式，逐一询问所有参数"
		echo "  --uninstall     卸载 WireGuard 及所有配置"
		echo "  --help          显示此帮助"
		echo ""
		echo "环境变量（零交互模式下可覆盖默认值）:"
		echo "  WG_PORT          服务端监听端口         （默认：随机 49152-65535）"
		echo "  WG_IF            WireGuard 接口名        （默认：wg0）"
		echo "  WG_IPV4_SERVER   服务端 wg 内网 IPv4     （默认：10.66.66.1）"
		echo "  WG_IPV6_SERVER   服务端 wg 内网 IPv6     （默认：fd42:42:42::1）"
		echo "  WG_DNS_1         客户端 DNS 1            （默认：1.1.1.1）"
		echo "  WG_DNS_2         客户端 DNS 2            （默认：8.8.8.8）"
		echo "  WG_ALLOWED_IPS   客户端 AllowedIPs       （默认：0.0.0.0/0,::/0）"
		echo "  WG_NAME          客户端名称              （默认：clash-<随机>）"
		exit 0
		;;
	esac
done

# ---------- 工具函数 ----------
function installPackages() {
	if ! "$@"; then
		echo -e "${RED}软件包安装失败，请检查网络连接与包源配置。${NC}"
		exit 1
	fi
}

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo -e "${RED}请以 root 身份运行此脚本（或使用 sudo）${NC}"
		exit 1
	fi
}

function checkVirt() {
	if command -v virt-what &>/dev/null; then
		VIRT=$(virt-what)
	else
		VIRT=$(systemd-detect-virt)
	fi
	if [[ ${VIRT} == "openvz" ]]; then
		echo -e "${RED}不支持 OpenVZ 虚拟化，WireGuard 需要内核模块支持。${NC}"
		exit 1
	fi
	if [[ ${VIRT} == "lxc" ]]; then
		echo -e "${RED}不支持 LXC 容器。WireGuard 内核模块必须安装在宿主机上。${NC}"
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo -e "${RED}Debian ${VERSION_ID} 不受支持，请使用 Debian 10 (Buster) 或更新版本。${NC}"
			exit 1
		fi
		OS=debian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo -e "${RED}Ubuntu ${VERSION_ID} 不受支持，请使用 Ubuntu 18.04 或更新版本。${NC}"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			echo -e "${RED}Fedora ${VERSION_ID} 不受支持，请使用 Fedora 32 或更新版本。${NC}"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]]; then
			echo -e "${RED}CentOS 7 不受支持，请使用 CentOS Stream 8 / AlmaLinux 8 / Rocky Linux 8 或更新版本。${NC}"
			exit 1
		fi
	elif [[ -e /etc/oracle-release ]]; then
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	elif [[ -e /etc/alpine-release ]]; then
		OS=alpine
		if ! command -v virt-what &>/dev/null; then
			if ! (apk update && apk add virt-what); then
				echo -e "${ORANGE}virt-what 安装失败，跳过虚拟化检测。${NC}"
			fi
		fi
	else
		echo -e "${RED}不支持的操作系统。支持：Debian、Ubuntu、Fedora、CentOS、AlmaLinux、Rocky、Oracle、Arch、Alpine。${NC}"
		exit 1
	fi
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1
	if [ -z "${CLIENT_NAME}" ]; then
		echo "错误：getHomeDirForClient() 需要客户端名称参数" >&2
		exit 1
	fi
	if [ -e "/home/${CLIENT_NAME}" ]; then
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		if [ "${SUDO_USER}" == "root" ]; then
			HOME_DIR="/root"
		else
			HOME_DIR="/home/${SUDO_USER}"
		fi
	else
		HOME_DIR="/root"
	fi
	echo "$HOME_DIR"
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
}

# ---------- 参数配置 ----------

# 通过多个公网 IP 接口获取真实外网地址（解决云厂商 NAT 拿到内网地址的问题）
function detectPublicIP() {
	local ip
	ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) && echo "$ip" && return
	ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) && echo "$ip" && return
	ip=$(curl -s --max-time 5 https://icanhazip.com 2>/dev/null) && echo "$ip" && return
	# 兜底：从本地网卡取 scope global 地址
	ip=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${ip} ]]; then
		ip=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi
	echo "$ip"
}

function installQuestions() {
	if [[ ${INTERACTIVE} -eq 1 ]]; then
		# 交互模式：沿用母体风格逐一询问
		echo -e "${BLUE}=== WireGuard 节点安装（交互模式）===${NC}"
		echo ""

		SERVER_PUB_IP=$(detectPublicIP)
		read -rp "服务器公网地址（IPv4 / IPv6）: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

		SERVER_NIC="$(ip -4 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
		until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
			read -rp "出口网卡名称: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
		done

		until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
			read -rp "WireGuard 接口名称: " -e -i wg0 SERVER_WG_NIC
		done

		until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
			read -rp "服务端 wg 内网 IPv4: " -e -i 10.66.66.1 SERVER_WG_IPV4
		done

		until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
			read -rp "服务端 wg 内网 IPv6: " -e -i fd42:42:42::1 SERVER_WG_IPV6
		done

		RANDOM_PORT=$(shuf -i49152-65535 -n1)
		until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
			read -rp "监听端口 [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
		done

		until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
			read -rp "客户端 DNS 1: " -e -i 1.1.1.1 CLIENT_DNS_1
		done
		until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
			read -rp "客户端 DNS 2（可选，直接回车与 DNS 1 相同）: " -e -i 1.0.0.1 CLIENT_DNS_2
			if [[ ${CLIENT_DNS_2} == "" ]]; then
				CLIENT_DNS_2="${CLIENT_DNS_1}"
			fi
		done

		until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
			read -rp "AllowedIPs（默认路由所有流量）: " -e -i '0.0.0.0/0,::/0' ALLOWED_IPS
			if [[ ${ALLOWED_IPS} == "" ]]; then
				ALLOWED_IPS="0.0.0.0/0,::/0"
			fi
		done

		echo ""
		echo "参数已确认，即将开始安装..."
		read -n1 -r -p "按任意键继续..."
	else
		# 零交互模式：全部读取环境变量，缺省则取默认值
		echo -e "${BLUE}=== WireGuard 节点安装（零交互模式）===${NC}"
		echo -e "${ORANGE}检测公网 IP（可能需要几秒）...${NC}"

		SERVER_PUB_IP=$(detectPublicIP)
		if [[ -z ${SERVER_PUB_IP} ]]; then
			echo -e "${RED}无法自动检测公网 IP，请使用 --interactive 手动输入，或设置环境变量后重试。${NC}"
			exit 1
		fi
		echo -e "  公网 IP：${GREEN}${SERVER_PUB_IP}${NC}"

		SERVER_PUB_NIC="$(ip -4 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
		if [[ -z ${SERVER_PUB_NIC} ]]; then
			echo -e "${RED}无法检测默认出口网卡，请使用 --interactive 模式。${NC}"
			exit 1
		fi
		echo -e "  出口网卡：${GREEN}${SERVER_PUB_NIC}${NC}"

		SERVER_WG_NIC="${WG_IF:-wg0}"
		SERVER_WG_IPV4="${WG_IPV4_SERVER:-10.66.66.1}"
		SERVER_WG_IPV6="${WG_IPV6_SERVER:-fd42:42:42::1}"
		SERVER_PORT="${WG_PORT:-$(shuf -i49152-65535 -n1)}"
		CLIENT_DNS_1="${WG_DNS_1:-1.1.1.1}"
		CLIENT_DNS_2="${WG_DNS_2:-8.8.8.8}"
		ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0,::/0}"

		echo -e "  wg 接口：${GREEN}${SERVER_WG_NIC}${NC}  端口：${GREEN}${SERVER_PORT}${NC}"
		echo -e "  服务端内网：${GREEN}${SERVER_WG_IPV4}${NC} / ${GREEN}${SERVER_WG_IPV6}${NC}"
		echo ""
	fi
}

# ---------- 安装 WireGuard ----------

function installWireGuard() {
	installQuestions

	echo -e "\n${BLUE}>>> 安装 WireGuard 软件包${NC}"

	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
		apt-get update
		installPackages apt-get install -y wireguard iptables resolvconf
	elif [[ ${OS} == 'debian' ]]; then
		if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
			echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
			apt-get update
		fi
		apt-get update
		installPackages apt-get install -y iptables resolvconf
		installPackages apt-get install -y -t buster-backports wireguard
	elif [[ ${OS} == 'fedora' ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			installPackages dnf install -y dnf-plugins-core
			dnf copr enable -y jdoss/wireguard
			installPackages dnf install -y wireguard-dkms
		fi
		installPackages dnf install -y wireguard-tools iptables
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 8* ]]; then
			installPackages yum install -y epel-release elrepo-release
			installPackages yum install -y kmod-wireguard
		fi
		installPackages yum install -y wireguard-tools iptables
	elif [[ ${OS} == 'oracle' ]]; then
		installPackages dnf install -y oraclelinux-developer-release-el8
		dnf config-manager --disable -y ol8_developer
		dnf config-manager --enable -y ol8_developer_UEKR6
		dnf config-manager --save -y --setopt=ol8_developer_UEKR6.includepkgs='wireguard-tools*'
		installPackages dnf install -y wireguard-tools iptables
	elif [[ ${OS} == 'arch' ]]; then
		installPackages pacman -S --needed --noconfirm wireguard-tools
	elif [[ ${OS} == 'alpine' ]]; then
		apk update
		installPackages apk add wireguard-tools iptables
	fi

	if ! command -v wg &>/dev/null; then
		echo -e "${RED}WireGuard 安装失败，'wg' 命令未找到。请检查上方的安装输出。${NC}"
		exit 1
	fi

	mkdir /etc/wireguard >/dev/null 2>&1
	chmod 600 -R /etc/wireguard/

	echo -e "${BLUE}>>> 生成服务端密钥对${NC}"
	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# 持久化服务端参数，供后续重新运行脚本使用
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/wireguard/params

	# 写入服务端 [Interface] 配置
	echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

	# 防火墙规则：优先 firewalld，否则用 iptables PostUp/PostDown
	if pgrep firewalld; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
		FIREWALLD_IPV6_ADDRESS=$(echo "${SERVER_WG_IPV6}" | sed 's/:[^:]*$/:0/')
		echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --zone=public --remove-interface=${SERVER_WG_NIC} && firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	else
		echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	# 开启内核 IP 转发（持久化到 sysctl.d）
	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf

	if [[ ${OS} == 'fedora' ]]; then
		chmod -v 700 /etc/wireguard
		chmod -v 600 /etc/wireguard/*
	fi

	echo -e "${BLUE}>>> 启动 WireGuard 服务${NC}"
	if [[ ${OS} == 'alpine' ]]; then
		sysctl -p /etc/sysctl.d/wg.conf
		rc-update add sysctl
		ln -s /etc/init.d/wg-quick "/etc/init.d/wg-quick.${SERVER_WG_NIC}"
		rc-service "wg-quick.${SERVER_WG_NIC}" start
		rc-update add "wg-quick.${SERVER_WG_NIC}"
	else
		sysctl --system
		systemctl start "wg-quick@${SERVER_WG_NIC}"
		systemctl enable "wg-quick@${SERVER_WG_NIC}"
	fi

	newClient

	# 检查服务是否正常运行
	if [[ ${OS} == 'alpine' ]]; then
		rc-service --quiet "wg-quick.${SERVER_WG_NIC}" status
	else
		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	fi
	WG_RUNNING=$?

	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}警告：WireGuard 服务似乎未正常运行。${NC}"
		echo -e "${ORANGE}若提示 'Cannot find device ${SERVER_WG_NIC}'，请重启服务器后再试。${NC}"
		if [[ ${OS} == 'alpine' ]]; then
			echo -e "${ORANGE}检查状态：rc-service wg-quick.${SERVER_WG_NIC} status${NC}"
		else
			echo -e "${ORANGE}检查状态：systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		fi
	else
		echo -e "\n${GREEN}WireGuard 服务运行正常。${NC}"
	fi
}

# ---------- 生成客户端配置 + Clash YAML ----------

function generateClashYaml() {
	# 所有变量均由调用方（newClient）设置完毕后才调用此函数
	local CLIENT_PUB_IP="${SERVER_PUB_IP}"
	# IPv6 地址需要方括号（Clash 配置中直接用裸地址即可，括号由 endpoint 字段处理）
	local CLASH_SERVER="${SERVER_PUB_IP}"
	if [[ ${CLASH_SERVER} == *"["* ]]; then
		CLASH_SERVER="${CLASH_SERVER//[/}"
		CLASH_SERVER="${CLASH_SERVER//]/}"
	fi
	local CLASH_PORT="${SERVER_PORT}"
	local OUT="/root/wg-clash.yaml"

	cat >"${OUT}" <<EOF
# Clash Meta / Mihomo WireGuard 代理配置
# 由 wireguard-install.sh 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 使用方法：将下方 proxies 节点复制进 Clash 配置文件，并在 proxy-groups 中引用代理名称

proxies:
  - name: "WG-${CLIENT_NAME}"
    type: wireguard
    server: "${CLASH_SERVER}"
    port: ${CLASH_PORT}
    ip: "${CLIENT_WG_IPV4}/32"
    ipv6: "${CLIENT_WG_IPV6}/128"
    private-key: "${CLIENT_PRIV_KEY}"
    public-key: "${SERVER_PUB_KEY}"
    pre-shared-key: "${CLIENT_PRE_SHARED_KEY}"
    udp: true
    mtu: 1420
    dns:
      - "${CLIENT_DNS_1}"
      - "${CLIENT_DNS_2}"
    workers: 0
    remote-dns-resolve: true
    allowed-ips:
      - "0.0.0.0/0"
      - "::/0"
EOF

	echo ""
	echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━ Clash 配置已生成 ━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo -e "${GREEN}文件路径：${OUT}${NC}"
	echo ""
	echo -e "${BLUE}配置内容预览：${NC}"
	cat "${OUT}"
	echo ""
	echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo ""
	echo -e "使用方式：将上方 ${ORANGE}proxies${NC} 节点复制到 Clash Meta / Mihomo 配置文件中，"
	echo -e "然后在 proxy-groups 中添加 ${ORANGE}\"WG-${CLIENT_NAME}\"${NC} 即可使用。"
}

function newClient() {
	# IPv6 地址需要用方括号作为 endpoint
	if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
		if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
			SERVER_PUB_IP="[${SERVER_PUB_IP}]"
		fi
	fi
	ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	# 客户端名称：环境变量 WG_NAME 优先，否则自动生成 clash-XXXXXX
	if [[ -n "${WG_NAME}" ]]; then
		if [[ ! "${WG_NAME}" =~ ^[a-zA-Z0-9_-]+$ || ${#WG_NAME} -ge 16 ]]; then
			echo -e "${ORANGE}WG_NAME 格式无效（仅支持字母/数字/下划线/横线，最多 15 字符），已自动生成名称。${NC}"
			CLIENT_NAME="clash-$(printf '%06x' $((RANDOM * 65536 + RANDOM)))"
		else
			CLIENT_NAME="${WG_NAME}"
		fi
	elif [[ ${INTERACTIVE} -eq 1 ]]; then
		CLIENT_EXISTS=1
		until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
			read -rp "客户端名称: " -e CLIENT_NAME
			CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/wireguard/${SERVER_WG_NIC}.conf")
			if [[ ${CLIENT_EXISTS} != 0 ]]; then
				echo -e "${ORANGE}该客户端名称已存在，请换一个。${NC}"
			fi
		done
	else
		CLIENT_NAME="clash-$(printf '%06x' $((RANDOM * 65536 + RANDOM)))"
	fi

	# 自动分配客户端内网 IPv4（从 .2 开始，找第一个未占用的）
	# 用 awk 切取网段，避免末位数字拼接歧义
	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${BASE_IP}\.${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf" 2>/dev/null || echo 0)
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo -e "${RED}子网已满（最多支持 253 个客户端）。${NC}"
		exit 1
	fi

	CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"

	BASE_IPV6=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
	CLIENT_WG_IPV6="${BASE_IPV6}::${DOT_IP}"

	# 生成客户端密钥对与预共享密钥
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	# 写入客户端原生 wg-quick 配置（留作备用/调试）
	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# 将客户端注册为服务端的 peer
	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	# 热重载（无需重启服务）；用临时文件替代进程替换，兼容无 /dev/fd 的系统
	local _TMP
	_TMP=$(mktemp)
	wg-quick strip "${SERVER_WG_NIC}" >"${_TMP}"
	wg syncconf "${SERVER_WG_NIC}" "${_TMP}"
	rm -f "${_TMP}"

	echo -e "${GREEN}原生 wg 配置：${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"

	# 核心输出：生成 Clash YAML
	generateClashYaml
}

# ---------- 卸载 ----------

function uninstallWg() {
	echo ""
	echo -e "${RED}警告：此操作将卸载 WireGuard 并删除所有配置文件！${NC}"
	echo -e "${ORANGE}如需保留配置，请先备份 /etc/wireguard 目录。${NC}"
	echo ""
	read -rp "确认卸载？[y/N]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		checkOS

		if [[ ${OS} == 'alpine' ]]; then
			rc-service "wg-quick.${SERVER_WG_NIC}" stop
			rc-update del "wg-quick.${SERVER_WG_NIC}"
			unlink "/etc/init.d/wg-quick.${SERVER_WG_NIC}"
			rc-update del sysctl
		else
			systemctl stop "wg-quick@${SERVER_WG_NIC}"
			systemctl disable "wg-quick@${SERVER_WG_NIC}"
		fi

		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get remove -y wireguard wireguard-tools
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y --noautoremove wireguard-tools
			if [[ ${VERSION_ID} -lt 32 ]]; then
				dnf remove -y --noautoremove wireguard-dkms
				dnf copr disable -y jdoss/wireguard
			fi
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			yum remove -y --noautoremove wireguard-tools
			if [[ ${VERSION_ID} == 8* ]]; then
				yum remove --noautoremove kmod-wireguard
			fi
		elif [[ ${OS} == 'oracle' ]]; then
			yum remove --noautoremove wireguard-tools
		elif [[ ${OS} == 'arch' ]]; then
			pacman -Rs --noconfirm wireguard-tools
		elif [[ ${OS} == 'alpine' ]]; then
			apk del wireguard-tools
		fi

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/wg.conf

		if [[ ${OS} == 'alpine' ]]; then
			true # Alpine 服务已在上面停止
		else
			sysctl --system
			systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
		fi
		WG_RUNNING=$?

		if [[ ${WG_RUNNING} -eq 0 ]]; then
			echo -e "${RED}WireGuard 卸载可能未完全成功，请手动确认。${NC}"
			exit 1
		else
			echo -e "${GREEN}WireGuard 已成功卸载。${NC}"
			exit 0
		fi
	else
		echo "已取消卸载。"
	fi
}

# ============================================================
# 主入口
# ============================================================

# 卸载模式：直接处理，不需要 initialCheck
if [[ ${DO_UNINSTALL} -eq 1 ]]; then
	isRoot
	if [[ ! -e /etc/wireguard/params ]]; then
		echo -e "${ORANGE}未检测到 WireGuard 安装记录（/etc/wireguard/params 不存在）。${NC}"
		exit 1
	fi
	source /etc/wireguard/params
	uninstallWg
	exit 0
fi

initialCheck

if [[ -e /etc/wireguard/params ]]; then
	# 已安装：重新生成一份客户端 + Clash 配置
	source /etc/wireguard/params
	echo -e "${GREEN}检测到 WireGuard 已安装（公网 IP：${SERVER_PUB_IP}，端口：${SERVER_PORT}）${NC}"
	echo ""
	echo "  • 继续将为你生成新的客户端配置并输出 Clash YAML"
	echo "  • 卸载请运行：bash $0 --uninstall"
	echo ""
	if [[ ${INTERACTIVE} -eq 0 ]]; then
		echo -e "${ORANGE}按 Ctrl-C 退出，或等待 5 秒自动继续...${NC}"
		sleep 5
	else
		read -rp "按回车继续 / Ctrl-C 退出 " _
	fi
	newClient
else
	# 未安装：完整安装流程
	installWireGuard
fi
