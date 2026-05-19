#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT_DIR="${SCRIPT_DIR}/.."

DOCKER_BUILDKIT_CONFIG_DIR="${DEPLOY_SCRIPT_DIR}/buildkit"
DOCKER_APT_SOURCES_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/debian.sources"
DOCKER_NPMRC_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/npmrc"

SAFE_EXEC_IMAGE="safe-exec:latest"
SAFE_EXEC_DIR="${DEPLOY_SCRIPT_DIR}/safe-exec"

REMOTE_HOST=""
DEPLOY_DIR=""
CODER_COPILOT_CONFIG_DIR=""
CODER_KIMI_CONFIG_DIR=""
CODER_IMAGE=""
COPILOT_VERSION=""
KIMI_VERSION=""

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
		--copilot-version)
			COPILOT_VERSION="$2"
			shift 2
			;;
		--kimi-version)
			KIMI_VERSION="$2"
			shift 2
			;;
		--coder-image)
			CODER_IMAGE="$2"
			shift 2
			;;
		*)
			echo "错误: 未知参数 $1"
			exit 1
			;;
	esac
done

if [ -z "${COPILOT_VERSION}" ] || [ -z "${KIMI_VERSION}" ] || [ -z "${CODER_IMAGE}" ]; then
	echo "错误: 必须指定 --copilot-version, --kimi-version 和 --coder-image"
	exit 1
fi

if [ -z "${REMOTE_HOST}" ] || [ -z "${DEPLOY_DIR}" ]; then
	echo "用法: deploy_coder.sh --remote-host <host> --deploy-dir <dir>"
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

DOCKER_BUILD_SECRET_ARGS=(
	--secret "id=openclaw_debian_sources,src=${DOCKER_APT_SOURCES_FILE}"
	--secret "id=openclaw_npmrc,src=${DOCKER_NPMRC_FILE}"
)

CODER_COPILOT_CONFIG_DIR="${CODER_COPILOT_CONFIG_DIR:-~/.copilot}"
CODER_KIMI_CONFIG_DIR="${CODER_KIMI_CONFIG_DIR:-~/.kimi}"

echo "=> 使用 Copilot CLI 版本: ${COPILOT_VERSION}"
echo "=> 使用 Kimi CLI 版本: ${KIMI_VERSION}"

echo "=> 构建 safe-exec 基础镜像${SAFE_EXEC_IMAGE} ..."
DOCKER_BUILDKIT=1 docker build --provenance=false \
	"${DOCKER_BUILD_SECRET_ARGS[@]}" \
	-t "${SAFE_EXEC_IMAGE}" \
	-f "${SAFE_EXEC_DIR}/Dockerfile" "${SAFE_EXEC_DIR}"

echo "=> 构建镜像 ${CODER_IMAGE} ..."
DOCKER_BUILDKIT=1 docker build --provenance=false \
	"${DOCKER_BUILD_SECRET_ARGS[@]}" \
	--build-arg "COPILOT_VERSION=${COPILOT_VERSION}" \
	--build-arg "KIMI_VERSION=${KIMI_VERSION}" \
	-t "${CODER_IMAGE}" \
	-f "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}"

echo "=> 将 Copilot Harness 镜像导入 ${REMOTE_HOST} (podman save & load) ..."
LOCAL_HASH=$(docker inspect --format='{{.Id}}' "${CODER_IMAGE}" 2>/dev/null | sed 's/^[^:]\+://' || true)
REMOTE_HASH=$(ssh "${REMOTE_HOST}" "podman image inspect --format='{{.Id}}' ${CODER_IMAGE} 2>/dev/null | sed 's/^[^:]\+://' || true")

if [ -n "${REMOTE_HASH}" ] && [ "${LOCAL_HASH}" = "${REMOTE_HASH}" ]; then
	echo "远程主机 ${REMOTE_HOST} 已存在镜像 ${CODER_IMAGE} 且 hash 一致，跳过导入步骤。"
  else
	echo "远程主机缺少该镜像或 hash 不一致(LOCAL: '${LOCAL_HASH}'，REMOTE: '${REMOTE_HASH})'，将其导出并通过 ssh 的标准输入直接载入远程节点 ..."
	docker save "${CODER_IMAGE}" | ssh "${REMOTE_HOST}" "podman load"
  fi

LOCAL_CODER_BUNDLE_DIR=""
cleanup_coder_secret_bundle() {
  if [ -n "${LOCAL_CODER_BUNDLE_DIR:-}" ] && [ -d "${LOCAL_CODER_BUNDLE_DIR}" ]; then
    rm -rf "${LOCAL_CODER_BUNDLE_DIR}"
  fi
}
trap cleanup_coder_secret_bundle EXIT

require_cmd keepassxc-cli
[ -n "${AGENT_SECRET_DB_PASSWORD:-}" ] || fail "AGENT_SECRET_DB_PASSWORD 环境变量未设置"
[ -n "${COPILOT_GITHUB_TOKEN:-}" ] || fail "COPILOT_GITHUB_TOKEN 环境变量未设置"
[ -n "${KIMI_API_KEY:-}" ] || fail "KIMI_API_KEY 环境变量未设置"

LOCAL_CODER_BUNDLE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coder-secret-bundle.XXXXXX")"

deploy_coder_secret_bundle() {
  local bundle_name="$1"
  local secret_path="$2"
  local secret_value="$3"

  echo "=> 在本机打包 ${bundle_name} Keepass 密钥库 ..."
  local local_db_path="${LOCAL_CODER_BUNDLE_DIR}/${bundle_name}-secrets.kdbx"
  local local_pass_path="${LOCAL_CODER_BUNDLE_DIR}/${bundle_name}-secrets.pass"

  printf '%s\n%s\n' "${AGENT_SECRET_DB_PASSWORD}" "${AGENT_SECRET_DB_PASSWORD}" | \
    keepassxc-cli db-create -q -p "${local_db_path}" >/dev/null 2>&1

  upsert_keepass_secret "${local_db_path}" "${AGENT_SECRET_DB_PASSWORD}" "${secret_path}" "${secret_value}"

  printf '%s' "${AGENT_SECRET_DB_PASSWORD}" > "${local_pass_path}"
  chmod 600 "${local_db_path}" "${local_pass_path}"

  echo "=> 复制 ${bundle_name} Keepass 密钥库到远程服务器 ..."
  local remote_secrets_dir="${DEPLOY_DIR}/secrets"
  ssh "${REMOTE_HOST}" "mkdir -p ${remote_secrets_dir}"
  scp "${local_db_path}" "${REMOTE_HOST}:${remote_secrets_dir}/${bundle_name}-secrets.kdbx"
  scp "${local_pass_path}" "${REMOTE_HOST}:${remote_secrets_dir}/${bundle_name}-secrets.pass"
  ssh "${REMOTE_HOST}" "chmod 600 ${remote_secrets_dir}/${bundle_name}-secrets.kdbx ${remote_secrets_dir}/${bundle_name}-secrets.pass"
}

deploy_coder_secret_bundle "copilot" "copilot/gh_token" "${COPILOT_GITHUB_TOKEN}"
deploy_coder_secret_bundle "kimi" "kimi/api_key" "${KIMI_API_KEY}"

echo "=> 创建 copilot 配置目录 ${CODER_COPILOT_CONFIG_DIR} ..."
ssh "${REMOTE_HOST}" "mkdir -p ${CODER_COPILOT_CONFIG_DIR}"
if [ -d "${SCRIPT_DIR}/copilot" ] && [ "$(ls -A ${SCRIPT_DIR}/copilot 2>/dev/null)" ]; then
  scp "${SCRIPT_DIR}"/copilot/* "${REMOTE_HOST}:${CODER_COPILOT_CONFIG_DIR}/"
fi

echo "=> 创建 kimi 配置目录 ${CODER_KIMI_CONFIG_DIR} ..."
ssh "${REMOTE_HOST}" "mkdir -p ${CODER_KIMI_CONFIG_DIR}"
if [ -d "${SCRIPT_DIR}/kimi" ] && [ "$(ls -A ${SCRIPT_DIR}/kimi 2>/dev/null)" ]; then
  scp "${SCRIPT_DIR}"/kimi/* "${REMOTE_HOST}:${CODER_KIMI_CONFIG_DIR}/"
fi

echo "=> Coder Harness 部署完成。"
