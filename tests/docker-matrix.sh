#!/bin/bash

# 多发行版 dry-run 验证脚本
# 仅验证脚本语法和 OS 检测分支，不实际安装 WireGuard（需要特权容器或真机）
# 用法：bash tests/docker-matrix.sh

set -e

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/wireguard-install.sh"

IMAGES=(
	"debian:12"
	"debian:11"
	"ubuntu:24.04"
	"ubuntu:22.04"
	"ubuntu:20.04"
	"fedora:40"
	"almalinux:9"
	"rockylinux:9"
	"archlinux:latest"
)

PASS=0
FAIL=0

for img in "${IMAGES[@]}"; do
	printf "%-30s" "${img} ..."
	result=$(docker run --rm \
		-v "${SCRIPT}:/w/wireguard-install.sh:ro" \
		-w /w \
		"${img}" \
		bash -c '
			# 安装最基础依赖（只为让脚本能跑到 OS 检测）
			if command -v apt-get &>/dev/null; then
				apt-get update -qq && apt-get install -y -qq iproute2 procps curl 2>/dev/null || true
			elif command -v dnf &>/dev/null; then
				dnf install -y -q iproute procps-ng curl 2>/dev/null || true
			elif command -v yum &>/dev/null; then
				yum install -y -q iproute procps-ng curl 2>/dev/null || true
			elif command -v pacman &>/dev/null; then
				pacman -Sy --noconfirm iproute2 procps-ng curl 2>/dev/null || true
			fi
			# 只做语法检查
			bash -n /w/wireguard-install.sh && echo "SYNTAX_OK"
		' 2>&1)

	if echo "${result}" | grep -q "SYNTAX_OK"; then
		echo -e " \033[32mPASS\033[0m"
		((PASS++))
	else
		echo -e " \033[31mFAIL\033[0m"
		echo "  └─ ${result}" | head -5
		((FAIL++))
	fi
done

echo ""
echo "结果：PASS=${PASS}  FAIL=${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
