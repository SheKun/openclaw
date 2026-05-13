#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_DIR="${SCRIPT_DIR}/../.."
DOCKER_BUILDKIT_CONFIG_DIR="${DEPLOY_SCRIPT_DIR}/buildkit"
DOCKER_APT_SOURCES_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/debian.sources"
DOCKER_NPMRC_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/npmrc"

REMOTE_HOST=""
DEPLOY_DIR=""
CODER_HARNESS_CONFIG_DIR=""
CODER_COPILOT_IMAGE=""

while [ "$#" -gt 0 ]; do
	case "$1" in
		--remote-host)
			REMOTE_HOST="$2"
			shift 2
			;;
		--deploy-dir)
			DEPLOY_DIR="$2"
			shift 2
			;;
		--coder-harness-config-dir)
			CODER_HARNESS_CONFIG_DIR="$2"
			shift 2
			;;
		--coder-copilot-image)
			CODER_COPILOT_IMAGE="$2"
			shift 2
			;;
		*)
			echo "错误: 未知参数 $1"
			exit 1
			;;
	esac
done

if [ -z "${REMOTE_HOST}" ] || [ -z "${DEPLOY_DIR}" ] || [ -z "${CODER_HARNESS_CONFIG_DIR}" ] || [ -z "${CODER_COPILOT_IMAGE}" ]; then
	echo "用法: deploy_copilot.sh --remote-host <host> --deploy-dir <dir> --coder-harness-config-dir <dir> --coder-copilot-image <image>"
	exit 1
fi

for required_file in "${DOCKER_APT_SOURCES_FILE}" "${DOCKER_NPMRC_FILE}"; do
	if [ ! -f "${required_file}" ]; then
		echo "错误: 未找到 BuildKit 镜像源配置文件 (${required_file})"
		exit 1
	fi
done

DOCKER_BUILD_SECRET_ARGS=(
	--secret "id=openclaw_debian_sources,src=${DOCKER_APT_SOURCES_FILE}"
	--secret "id=openclaw_npmrc,src=${DOCKER_NPMRC_FILE}"
)

COPILOT_VERSION="${COPILOT_VERSION:-1.0.38}"
if [ -z "${COPILOT_VERSION}" ]; then
	if ! command -v npm >/dev/null 2>&1; then
		echo "错误: 需要 npm 命令来查询 Copilot 最新版本，请先安装 npm。"
		exit 1
	fi
	COPILOT_VERSION=$(npm view @github/copilot version 2>/dev/null | tr -d '[:space:]')
	if [ -z "${COPILOT_VERSION}" ]; then
		echo "错误: 无法获取 @github/copilot 的最新版本号。"
		exit 1
	fi
fi

COPILOT_HARNESS_BASE_IMAGE="node:22-bookworm-slim"

echo "=> 使用 Copilot CLI 版本: ${COPILOT_VERSION}"
echo "=> 将构建并部署 Harness 镜像: ${CODER_COPILOT_IMAGE}"

echo "=> 检查是否存在镜像 ${CODER_COPILOT_IMAGE} ..."
if docker image inspect "${CODER_COPILOT_IMAGE}" >/dev/null 2>&1; then
	echo "镜像 ${CODER_COPILOT_IMAGE} 已存在，跳过本地构建。"
else
	echo "镜像 ${CODER_COPILOT_IMAGE} 不存在，开始构建 Copilot Harness 镜像 ..."
	DOCKER_BUILDKIT=1 docker build --provenance=false \
		"${DOCKER_BUILD_SECRET_ARGS[@]}" \
		--build-arg "BASE_IMAGE=${COPILOT_HARNESS_BASE_IMAGE}" \
		--build-arg "COPILOT_VERSION=${COPILOT_VERSION}" \
		-t "${CODER_COPILOT_IMAGE}" \
		-f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"
fi

echo "=> 将 Copilot Harness 镜像导入 ${REMOTE_HOST} (podman save & load) ..."
if ssh "${REMOTE_HOST}" "podman image inspect ${CODER_COPILOT_IMAGE} >/dev/null 2>&1"; then
	echo "远程主机 ${REMOTE_HOST} 已存在镜像 ${CODER_COPILOT_IMAGE}，跳过导入步骤。"
else
	echo "远程主机缺少该镜像，将其导出并通过 ssh 的标准输入直接载入远程节点 ..."
	docker save "${CODER_COPILOT_IMAGE}" | ssh "${REMOTE_HOST}" "podman load"
fi

echo "=> 复制 Copilot Harness 部署文件到远程服务器 ..."
scp "${SCRIPT_DIR}/coder_entry.sh" "${REMOTE_HOST}:${DEPLOY_DIR}/coder_entry.sh"
scp "${SCRIPT_DIR}/coder_acp_cmd.sh" "${REMOTE_HOST}:${DEPLOY_DIR}/coder_acp_cmd.sh"
ssh "${REMOTE_HOST}" "chmod 700 ${DEPLOY_DIR}/coder_entry.sh ${DEPLOY_DIR}/coder_acp_cmd.sh"

echo "=> 创建 coder harness 配置目录 ${CODER_HARNESS_CONFIG_DIR} ..."
ssh "${REMOTE_HOST}" "
	mkdir -p ${CODER_HARNESS_CONFIG_DIR}
	mkdir -p ${CODER_HARNESS_CONFIG_DIR}/.ssh
	mkdir -p ${CODER_HARNESS_CONFIG_DIR}/.copilot
"

echo "=> 生成 SSH environment 文件 (Copilot BYOK 变量，通过卷挂载注入容器) ..."
ssh "${REMOTE_HOST}" "mkdir -p ${CODER_HARNESS_CONFIG_DIR}/.ssh"
ssh "${REMOTE_HOST}" "cat > ${CODER_HARNESS_CONFIG_DIR}/.ssh/environment && chmod 600 ${CODER_HARNESS_CONFIG_DIR}/.ssh/environment" <<EOF
GH_TOKEN=${COPILOT_GITHUB_TOKEN:-}
EOF

echo "=> Copilot Harness 部署完成。"
