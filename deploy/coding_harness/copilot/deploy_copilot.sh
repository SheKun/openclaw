#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_DIR="${SCRIPT_DIR}/../.."
DOCKER_BUILDKIT_CONFIG_DIR="${DEPLOY_SCRIPT_DIR}/buildkit"
DOCKER_APT_SOURCES_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/debian.sources"
DOCKER_NPMRC_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/npmrc"

SAFE_EXEC_IMAGE="safe-exec:latest"
SAFE_EXEC_DIR="${DEPLOY_SCRIPT_DIR}/safe-exec"

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
		*)
			echo "错误: 未知参数 $1"
			exit 1
			;;
	esac
done

if [ -z "${REMOTE_HOST}" ] || [ -z "${DEPLOY_DIR}" ]; then
	echo "用法: deploy_copilot.sh --remote-host <host> --deploy-dir <dir>"
	exit 1
fi

for required_file in "${DOCKER_APT_SOURCES_FILE}" "${DOCKER_NPMRC_FILE}"; do
	if [ ! -f "${required_file}" ]; then
		echo "错误: 未找到 BuildKit 镜像源配置文件 (${required_file})"
		exit 1
	fi
done

# 加载通用部署工具
source "${DOCKER_BUILDKIT_CONFIG_DIR}/deploy_tool.sh"

echo "=> 加载环境变量..."
GLOBAL_ENV_FILE="${DEPLOY_SCRIPT_DIR}/../.env"
LOCAL_ENV_FILE="${DEPLOY_SCRIPT_DIR}/.env"

load_env_file_if_exists "${GLOBAL_ENV_FILE}"
load_env_file_if_exists "${LOCAL_ENV_FILE}"

LOCAL_COPILOT_BUNDLE_DIR=""
cleanup_copilot_secret_bundle() {
  if [ -n "${LOCAL_COPILOT_BUNDLE_DIR:-}" ] && [ -d "${LOCAL_COPILOT_BUNDLE_DIR}" ]; then
    rm -rf "${LOCAL_COPILOT_BUNDLE_DIR}"
  fi
}
trap cleanup_copilot_secret_bundle EXIT

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

CODER_HARNESS_CONFIG_DIR="${CODER_HARNESS_CONFIG_DIR:-~/.coder-harness}"
CODER_COPILOT_IMAGE="${CODER_COPILOT_IMAGE:-krepus.com/coder-copilot:${COPILOT_VERSION}}"

echo "=> 使用 Copilot CLI 版本: ${COPILOT_VERSION}"
echo "=> 将构建并部署 Harness 镜像: ${CODER_COPILOT_IMAGE}"

echo "=> 构建 safe-exec 基础镜像${SAFE_EXEC_IMAGE} ..."
DOCKER_BUILDKIT=1 docker build --provenance=false \
	"${DOCKER_BUILD_SECRET_ARGS[@]}" \
	-t "${SAFE_EXEC_IMAGE}" \
	-f "${SAFE_EXEC_DIR}/Dockerfile" "${SAFE_EXEC_DIR}"

echo "=> 构建镜像 ${CODER_COPILOT_IMAGE} ..."
DOCKER_BUILDKIT=1 docker build --provenance=false \
	"${DOCKER_BUILD_SECRET_ARGS[@]}" \
	--build-arg "COPILOT_VERSION=${COPILOT_VERSION}" \
	-t "${CODER_COPILOT_IMAGE}" \
	-f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"

echo "=> 将 Copilot Harness 镜像导入 ${REMOTE_HOST} (podman save & load) ..."
LOCAL_HASH=$(docker inspect --format='{{.Id}}' "${CODER_COPILOT_IMAGE}" 2>/dev/null | sed 's/^[^:]\+://' || true)
REMOTE_HASH=$(ssh "${REMOTE_HOST}" "podman image inspect --format='{{.Id}}' ${CODER_COPILOT_IMAGE} 2>/dev/null | sed 's/^[^:]\+://' || true")

if [ -n "${REMOTE_HASH}" ] && [ "${LOCAL_HASH}" = "${REMOTE_HASH}" ]; then
	echo "远程主机 ${REMOTE_HOST} 已存在镜像 ${CODER_COPILOT_IMAGE} 且 hash 一致，跳过导入步骤。"
else
	echo "远程主机缺少该镜像或 hash 不一致(LOCAL: '${LOCAL_HASH}'，REMOTE: '${REMOTE_HASH})'，将其导出并通过 ssh 的标准输入直接载入远程节点 ..."
	docker save "${CODER_COPILOT_IMAGE}" | ssh "${REMOTE_HOST}" "podman load"
fi

# 准备并部署 Copilot 专属的 KeePassXC 密钥库
require_cmd keepassxc-cli
[ -n "${COPILOT_GITHUB_TOKEN:-}" ] || fail "COPILOT_GITHUB_TOKEN 环境变量未设置"
[ -n "${AGENT_SECRET_DB_PASSWORD:-}" ] || fail "AGENT_SECRET_DB_PASSWORD 环境变量未设置"

echo "=> 在本机打包 Copilot Keepass 密钥库 ..."
LOCAL_COPILOT_BUNDLE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/copilot-secret-bundle.XXXXXX")"
LOCAL_COPILOT_BUNDLE_DB_PATH="${LOCAL_COPILOT_BUNDLE_DIR}/copilot-secrets.kdbx"
LOCAL_COPILOT_BUNDLE_PASS_PATH="${LOCAL_COPILOT_BUNDLE_DIR}/copilot-secrets.pass"

printf '%s\n%s\n' "${AGENT_SECRET_DB_PASSWORD}" "${AGENT_SECRET_DB_PASSWORD}" | \
  keepassxc-cli db-create -q -p "${LOCAL_COPILOT_BUNDLE_DB_PATH}" >/dev/null 2>&1

upsert_keepass_secret "${LOCAL_COPILOT_BUNDLE_DB_PATH}" "${AGENT_SECRET_DB_PASSWORD}" "copilot/gh_token" "${COPILOT_GITHUB_TOKEN}"

printf '%s' "${AGENT_SECRET_DB_PASSWORD}" > "${LOCAL_COPILOT_BUNDLE_PASS_PATH}"
chmod 600 "${LOCAL_COPILOT_BUNDLE_DB_PATH}" "${LOCAL_COPILOT_BUNDLE_PASS_PATH}"

echo "=> 复制 Copilot Keepass 密钥库到远程服务器 ..."
REMOTE_SECRETS_DIR="${DEPLOY_DIR}/secrets"
ssh "${REMOTE_HOST}" "mkdir -p ${REMOTE_SECRETS_DIR}"
scp "${LOCAL_COPILOT_BUNDLE_DB_PATH}" "${REMOTE_HOST}:${REMOTE_SECRETS_DIR}/copilot-secrets.kdbx"
scp "${LOCAL_COPILOT_BUNDLE_PASS_PATH}" "${REMOTE_HOST}:${REMOTE_SECRETS_DIR}/copilot-secrets.pass"
ssh "${REMOTE_HOST}" "chmod 600 ${REMOTE_SECRETS_DIR}/copilot-secrets.kdbx ${REMOTE_SECRETS_DIR}/copilot-secrets.pass"

echo "=> 创建 coder harness 配置目录 ${CODER_HARNESS_CONFIG_DIR} ..."
ssh "${REMOTE_HOST}" "
	mkdir -p ${CODER_HARNESS_CONFIG_DIR}
"

echo "=> Copilot Harness 部署完成。"
