#!/bin/bash
# 依照 OpenClaw Docker 文档步骤：本地构造镜像，导出并通过 SSH 部署到远程服务器
# 目标主机: 默认为 rmbook，可通过第一个参数指定

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
DOCKER_BUILDKIT_CONFIG_DIR="${SCRIPT_DIR}/buildkit"
DOCKER_APT_SOURCES_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/debian.sources"
DOCKER_NPMRC_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/npmrc"
GLOBAL_ENV_FILE="${PROJECT_ROOT}/../.env"
LOCAL_ENV_FILE="${SCRIPT_DIR}/.env"
COPILOT_HARNESS_DIR="${SCRIPT_DIR}/coding_harness/copilot"
COPILOT_DEPLOY_SCRIPT="${COPILOT_HARNESS_DIR}/deploy_copilot.sh"

# ------- 版本控制量设置（可按需调整） -------
OPENCLAW_BUILD_SUFFIX="${OPENCLAW_BUILD_SUFFIX:-build202605151637}"
COPILOT_VERSION="${COPILOT_VERSION:-1.0.38}"
DOCKER_BUILD_SECRET_ARGS=(
  --secret "id=openclaw_debian_sources,src=${DOCKER_APT_SOURCES_FILE}"
  --secret "id=openclaw_npmrc,src=${DOCKER_NPMRC_FILE}"
)

OPENCLAW_EXTENSIONS=(
  browser
  lobster
  open-prose
  llm-task
  acpx
  document-extract
  memory-core
  active-memory
  feishu
  perplexity
)
OPENCLAW_DOCKER_JS_PACKAGES=(
  @tobilu/qmd
  @clawdbot/lobster
  clawhub
)
OPENCLAW_DOCKER_APT_PACKAGES=(
  keepassxc
  jq
  ripgrep
  openssh-client
)
BUNDLED_PLUGINS_TO_INSTALL=(
  memory-wiki
)
CUSTOM_EXTENSIONS=(
  guidance
)

REQUIRED_ENV_VARS=(
  AGENT_SECRET_DB_PASSWORD
  FEISHU_APP_SECRET_STEWARD
  FEISHU_APP_SECRET_CODER
  FEISHU_APP_SECRET_PLANNER
  LITELLM_API_KEY
)

# ------- 部署环境配置 -------
REMOTE_HOST="${1:-rmbook}"
DEPLOY_DIR="~/openclaw-deploy"

# OpenClaw
OPENCLAW_CONFIG_DIR="~/.openclaw"
CONFIG_JSON_PATH="${SCRIPT_DIR}/openclaw_conf.json"
CUSTOM_EXTENSIONS_DIR="${SCRIPT_DIR}/myextensions"
CUSTOM_EXTENSIONS_ARTIFACT_DIR="${CUSTOM_EXTENSIONS_DIR}/dist"

REMOTE_SECRETS_DIR="${DEPLOY_DIR}/secrets"
REMOTE_KEEPASS_DB_PATH="${REMOTE_SECRETS_DIR}/openclaw-secrets.kdbx"
REMOTE_KEEPASS_PASS_PATH="${REMOTE_SECRETS_DIR}/openclaw-secrets.pass"

GATEWAY_TLS_CERT_PATH_HOST="${OPENCLAW_CONFIG_DIR}/gateway/tls/gateway-cert.pem"
GATEWAY_TLS_KEY_PATH_HOST="${OPENCLAW_CONFIG_DIR}/gateway/tls/gateway-key.pem"
GATEWAY_TLS_CERT_PATH_CONTAINER="/home/node/.openclaw/gateway/tls/gateway-cert.pem"
GATEWAY_TLS_KEY_PATH_CONTAINER="/home/node/.openclaw/gateway/tls/gateway-key.pem"

OPENCLAW_LOG_LEVEL="${OPENCLAW_LOG_LEVEL:-info}"
OPENCLAW_TZ="${OPENCLAW_TZ:-UTC}"

# Exec Node
EXEC_NODE_CONFIG_DIR="~/.exec_node"

# Coder Harness
CODER_HARNESS_CONFIG_DIR="~/.coder-harness"

# ------- 脚本执行变量 -------

LOCAL_SECRET_BUNDLE_DIR=""
LOCAL_SECRET_BUNDLE_DB_PATH=""
LOCAL_SECRET_BUNDLE_PASS_PATH=""

OPENCLAW_VERSION=""
VERSION=""
IMAGE_NAME=""
DEFAULT_AGENT_ID=""
DEFAULT_AGENT_DIR=""
GATEWAY_TOKEN=""
OPENCLAW_PUB_KEY=""
OPENCLAW_GATEWAY_TLS_FINGERPRINT=""
CODER_COPILOT_IMAGE=""

step() {
  local idx="$1"
  local text="$2"
  echo ""
  echo "[${idx}/6] ${text}"
}

substep() {
  echo "  -> $1"
}

fail() {
  echo "错误: $1" >&2
  exit 1
}

cleanup_secret_bundle() {
  if [ -n "${LOCAL_SECRET_BUNDLE_DIR:-}" ] && [ -d "${LOCAL_SECRET_BUNDLE_DIR}" ]; then
    rm -rf "${LOCAL_SECRET_BUNDLE_DIR}"
  fi
}

load_env_file_if_exists() {
  local env_file="$1"
  if [ -f "${env_file}" ]; then
    substep "加载环境变量: ${env_file}"
    set -a
    source <(sed 's/\r//' "${env_file}")
    set +a
  fi
}

require_file() {
  local file_path="$1"
  [ -f "${file_path}" ] || fail "未找到文件 (${file_path})"
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "缺少命令 ${cmd}"
}

assert_required_env_vars() {
  local missing=()
  local var_name
  for var_name in "${REQUIRED_ENV_VARS[@]}"; do
    if [ -z "${!var_name:-}" ]; then
      missing+=("${var_name}")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    fail "以下环境变量未设置: ${missing[*]}"
  fi
}

upsert_keepass_secret() {
  local entry_path="$1"
  local secret_value="$2"
  local group_path="${entry_path%/*}"

  if [ "${group_path}" != "${entry_path}" ]; then
    echo "${AGENT_SECRET_DB_PASSWORD}" |
      keepassxc-cli mkdir -q "${LOCAL_SECRET_BUNDLE_DB_PATH}" "${group_path}" >/dev/null 2>&1 || true
  fi

  printf '%s\n%s\n%s\n' "${AGENT_SECRET_DB_PASSWORD}" "${secret_value}" "${secret_value}" |
    keepassxc-cli add -q -u "openclaw" -p "${LOCAL_SECRET_BUNDLE_DB_PATH}" "${entry_path}" >/dev/null 2>&1
}

build_keepass_secret_bundle() {
  substep "在本机打包 Keepass 密钥库"
  LOCAL_SECRET_BUNDLE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-secret-bundle.XXXXXX")"
  LOCAL_SECRET_BUNDLE_DB_PATH="${LOCAL_SECRET_BUNDLE_DIR}/openclaw-secrets.kdbx"
  LOCAL_SECRET_BUNDLE_PASS_PATH="${LOCAL_SECRET_BUNDLE_DIR}/openclaw-secrets.pass"

  printf '%s\n%s\n' "${AGENT_SECRET_DB_PASSWORD}" "${AGENT_SECRET_DB_PASSWORD}" |
    keepassxc-cli db-create -q -p "${LOCAL_SECRET_BUNDLE_DB_PATH}" >/dev/null 2>&1

  upsert_keepass_secret "feishu/stewardAppSecret" "${FEISHU_APP_SECRET_STEWARD}"
  upsert_keepass_secret "feishu/coderAppSecret" "${FEISHU_APP_SECRET_CODER}"
  upsert_keepass_secret "feishu/plannerAppSecret" "${FEISHU_APP_SECRET_PLANNER}"
  upsert_keepass_secret "litellm/apiKey" "${LITELLM_API_KEY}"
  upsert_keepass_secret "perplexity/apiKey" "${PERPLEXITY_API_KEY:-}"
  upsert_keepass_secret "agent/secretDbPassword" "${AGENT_SECRET_DB_PASSWORD}"

  printf '%s' "${AGENT_SECRET_DB_PASSWORD}" > "${LOCAL_SECRET_BUNDLE_PASS_PATH}"
  chmod 600 "${LOCAL_SECRET_BUNDLE_DB_PATH}" "${LOCAL_SECRET_BUNDLE_PASS_PATH}"
}

resolve_openclaw_identity() {
  OPENCLAW_VERSION=$(grep -m1 '"version":' package.json | awk -F'"' '{print $4}')
  [ -n "${OPENCLAW_VERSION}" ] || fail "无法从 package.json 获取版本号"

  VERSION="${OPENCLAW_VERSION}-${OPENCLAW_BUILD_SUFFIX}"
  IMAGE_NAME="krepus.com/openclaw:${VERSION}"
  CODER_COPILOT_IMAGE="krepus.com/coder-copilot:${COPILOT_VERSION}"

  DEFAULT_AGENT_ID=$(node -e '
const fs = require("node:fs");
const cfgPath = process.argv[1];
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
const list = Array.isArray(cfg?.agents?.list) ? cfg.agents.list : [];
const defaultAgent = list.find((entry) => entry && entry.default === true);
const fallbackAgent = list[0];
const id = (defaultAgent?.id || fallbackAgent?.id || "main").toString().trim();
process.stdout.write(id || "main");
' "${CONFIG_JSON_PATH}")

  DEFAULT_AGENT_DIR="${OPENCLAW_CONFIG_DIR}/agents/${DEFAULT_AGENT_ID}/agent"
  substep "默认 Agent: ${DEFAULT_AGENT_ID}"
}

build_openclaw_image_if_needed() {
  substep "检查本地镜像 ${IMAGE_NAME}"
  if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    substep "本地镜像已存在，跳过构建"
    return
  fi

  substep "开始构建 OpenClaw 镜像"
  local build_log="/tmp/openclaw-build-${IMAGE_NAME//[\/:]/_}.log"
  substep "构建日志: ${build_log}"

  DOCKER_BUILDKIT=1 docker build --progress=plain --provenance=false \
    "${DOCKER_BUILD_SECRET_ARGS[@]}" \
    --build-arg "OPENCLAW_EXTENSIONS=${OPENCLAW_EXTENSIONS[*]}" \
    --build-arg "OPENCLAW_DOCKER_JS_PACKAGES=${OPENCLAW_DOCKER_JS_PACKAGES[*]}" \
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES[*]}" \
    -t "${IMAGE_NAME}" -f Dockerfile . 2>&1 | tee "${build_log}"
}

ensure_remote_directories() {
  substep "创建远程目录"
  ssh "${REMOTE_HOST}" "
    mkdir -p ${DEPLOY_DIR}
    mkdir -p ${REMOTE_SECRETS_DIR}
    mkdir -p ${DEPLOY_DIR}/output/projects
    mkdir -p ${DEPLOY_DIR}/output/wiki
    mkdir -p ${DEPLOY_DIR}/myextensions
    mkdir -p ${DEPLOY_DIR}/workspaces
    mkdir -p ${OPENCLAW_CONFIG_DIR}
    mkdir -p ${OPENCLAW_CONFIG_DIR}/.ssh
    mkdir -p ${OPENCLAW_CONFIG_DIR}/.ssh/sockets
    mkdir -p ${OPENCLAW_CONFIG_DIR}/gateway/tls
    mkdir -p ${EXEC_NODE_CONFIG_DIR}
  "
}

ensure_remote_image() {
  substep "检查远程镜像 ${IMAGE_NAME}"
  if ssh "${REMOTE_HOST}" "podman image inspect ${IMAGE_NAME} >/dev/null 2>&1"; then
    substep "远程镜像已存在，跳过导入"
    return
  fi

  substep "导出并导入镜像到远程"
  docker save "${IMAGE_NAME}" | ssh "${REMOTE_HOST}" "podman load"
}

ensure_gateway_token() {
  local existing
  existing=$(
    ssh "${REMOTE_HOST}" "
        if [ -f ${DEPLOY_DIR}/.env ]; 
          then grep -m1 '^OPENCLAW_GATEWAY_TOKEN=' ${DEPLOY_DIR}/.env | cut -d'=' -f2- | tr -d \"\\\"'\"; 
        fi
    " || true)

  if [ -n "${existing}" ]; then
    GATEWAY_TOKEN="${existing}"
    substep "复用已有 Gateway Token"
    return
  fi

  GATEWAY_TOKEN="$(openssl rand -hex 32)"
  substep "生成新的 Gateway Token"
}

sync_openclaw_runtime_files() {
  substep "同步 OpenClaw 配置和密钥库"

  scp "${CONFIG_JSON_PATH}" "${REMOTE_HOST}:${OPENCLAW_CONFIG_DIR}/openclaw.json"
  scp "${SCRIPT_DIR}/exec-approvals.json" "${REMOTE_HOST}:${OPENCLAW_CONFIG_DIR}/exec-approvals.json"
  scp "${SCRIPT_DIR}/exec-approvals.json" "${REMOTE_HOST}:${EXEC_NODE_CONFIG_DIR}/exec-approvals.json"
  ssh "${REMOTE_HOST}" "
       chmod 600 ${OPENCLAW_CONFIG_DIR}/openclaw.json \
          ${OPENCLAW_CONFIG_DIR}/exec-approvals.json \
          ${EXEC_NODE_CONFIG_DIR}/exec-approvals.json
  "

  scp "${LOCAL_SECRET_BUNDLE_DB_PATH}" "${REMOTE_HOST}:${REMOTE_KEEPASS_DB_PATH}"
  scp "${LOCAL_SECRET_BUNDLE_PASS_PATH}" "${REMOTE_HOST}:${REMOTE_KEEPASS_PASS_PATH}"
  ssh "${REMOTE_HOST}" "chmod 600 ${REMOTE_KEEPASS_DB_PATH} ${REMOTE_KEEPASS_PASS_PATH}"

  ssh "${REMOTE_HOST}" "cat <<EOF > ${OPENCLAW_CONFIG_DIR}/.env
# OpenClaw 配置和启动脚本所需的明文环境变量
# 敏感环境变量通过 secret provider 提供
FEISHU_APP_ID_STEWARD=${FEISHU_APP_ID_STEWARD:-}
FEISHU_APP_ID_CODER=${FEISHU_APP_ID_CODER:-}
FEISHU_APP_ID_PLANNER=${FEISHU_APP_ID_PLANNER:-}
EOF
"
  scp "${SCRIPT_DIR}/start-gateway.sh" "${REMOTE_HOST}:${DEPLOY_DIR}/start-gateway.sh"
  scp "${SCRIPT_DIR}/exec_node_entry.sh" "${REMOTE_HOST}:${DEPLOY_DIR}/exec_node_entry.sh"
  scp "${SCRIPT_DIR}/create_ssh_user.sh" "${REMOTE_HOST}:${DEPLOY_DIR}/create_ssh_user.sh"
  scp "${SCRIPT_DIR}/keepassxc-vault.sh" "${REMOTE_HOST}:${DEPLOY_DIR}/keepassxc-vault.sh"
  scp "${SCRIPT_DIR}/launch_chrome.sh" "${REMOTE_HOST}:${DEPLOY_DIR}/launch_chrome.sh"
  ssh "${REMOTE_HOST}" "chmod 700 ${DEPLOY_DIR}/*.sh"
}

ensure_openclaw_ssh_identity() {
  substep "创建或复用 OpenClaw SSH 认证密钥"
  ssh "${REMOTE_HOST}" "
    if [ ! -f ${OPENCLAW_CONFIG_DIR}/.ssh/auth ]; then
      ssh-keygen -t ed25519 -f ${OPENCLAW_CONFIG_DIR}/.ssh/auth -N '' -C 'openclaw' -q
    fi
  "

  OPENCLAW_PUB_KEY=$(ssh "${REMOTE_HOST}" "cat ${OPENCLAW_CONFIG_DIR}/.ssh/auth.pub")
  ssh "${REMOTE_HOST}" "cat <<EOF > ${OPENCLAW_CONFIG_DIR}/.ssh/config
Host *
  IdentityFile ~/.ssh/auth
Host github.com
  HostName github.com
  User git
Host coder-copilot
  User root
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h:%p
  ControlPersist yes
Host cdp_tunnel
  HostName 172.17.0.1
  User cdp_tunnel
EOF
"
}

ensure_gateway_tls_cert() {
  substep "生成或复用 Gateway TLS 证书"
  ssh "${REMOTE_HOST}" "
    if [ ! -s ${GATEWAY_TLS_CERT_PATH_HOST} ] || [ ! -s ${GATEWAY_TLS_KEY_PATH_HOST} ]; then
      openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout ${GATEWAY_TLS_KEY_PATH_HOST} \
        -out ${GATEWAY_TLS_CERT_PATH_HOST} \
        -subj '/CN=openclaw-gateway'
      chmod 600 ${GATEWAY_TLS_KEY_PATH_HOST} ${GATEWAY_TLS_CERT_PATH_HOST}
    fi
  "

  local raw_fp
  raw_fp=$(ssh "${REMOTE_HOST}" "openssl x509 -in ${GATEWAY_TLS_CERT_PATH_HOST} -noout -fingerprint -sha256 | sed -E 's/^[Ss][Hh][Aa]256 Fingerprint=//' | tr -d '\\r'")
  [ -n "${raw_fp}" ] || fail "无法读取网关 TLS 证书指纹"

  OPENCLAW_GATEWAY_TLS_FINGERPRINT="SHA256:${raw_fp}"
  substep "网关证书指纹: ${OPENCLAW_GATEWAY_TLS_FINGERPRINT}"
}

sync_custom_extensions() {
  if [ ${#CUSTOM_EXTENSIONS[@]} -eq 0 ]; then
    return
  fi

  substep "编译并上传自定义插件"
  require_cmd pnpm

  ssh "${REMOTE_HOST}" "find ${DEPLOY_DIR}/myextensions -mindepth 1 -maxdepth 1 -exec rm -rf {} +"

  rm -rf "${CUSTOM_EXTENSIONS_ARTIFACT_DIR}"
  mkdir -p "${CUSTOM_EXTENSIONS_ARTIFACT_DIR}"

  local ext
  for ext in "${CUSTOM_EXTENSIONS[@]}"; do
    local ext_src_dir="${CUSTOM_EXTENSIONS_DIR}/${ext}"
    if [ ! -d "${ext_src_dir}" ]; then
      substep "警告: 找不到扩展目录 ${ext_src_dir}，跳过"
      continue
    fi
    if [ ! -f "${ext_src_dir}/package.json" ]; then
      substep "警告: 扩展 ${ext} 缺少 package.json，跳过"
      continue
    fi

    rm -rf "${ext_src_dir}/dist"
    mkdir -p "${ext_src_dir}/dist"

    (
      cd "${ext_src_dir}"
      pnpm exec tsc --ignoreConfig index.ts \
        --module esnext \
        --moduleResolution bundler \
        --target es2022 \
        --outDir dist \
        --declaration false \
        --sourceMap false \
        --skipLibCheck \
        --noCheck

      local packed
      packed=$(pnpm pack --pack-destination "${CUSTOM_EXTENSIONS_ARTIFACT_DIR}" 2>/dev/null | tail -1)
      scp "${packed}" "${REMOTE_HOST}:${DEPLOY_DIR}/myextensions/"
    )
  done
}

write_remote_compose_env() {
  substep "写入远程 .env（compose + runtime）"

  ssh "${REMOTE_HOST}" "cat <<EOF > ${DEPLOY_DIR}/.env
# OpenClaw Gateway 配置
OPENCLAW_IMAGE='${IMAGE_NAME}'
OPENCLAW_CONFIG_DIR='${OPENCLAW_CONFIG_DIR}'
OPENCLAW_AGENT_DIR='${DEFAULT_AGENT_DIR}'
PI_CODING_AGENT_DIR='${DEFAULT_AGENT_DIR}'
OPENCLAW_TZ='${OPENCLAW_TZ}'
OPENCLAW_LOG_LEVEL='${OPENCLAW_LOG_LEVEL}'
BUNDLED_PLUGINS_TO_INSTALL='${BUNDLED_PLUGINS_TO_INSTALL[*]:-}'
OPENCLAW_GATEWAY_TOKEN='${GATEWAY_TOKEN}'
FEISHU_APP_ID_STEWARD='${FEISHU_APP_ID_STEWARD:-}'
FEISHU_APP_ID_CODER='${FEISHU_APP_ID_CODER:-}'
FEISHU_APP_ID_PLANNER='${FEISHU_APP_ID_PLANNER:-}'

# Coder Harness 配置
CODER_HARNESS_CONFIG_DIR='${CODER_HARNESS_CONFIG_DIR}'
CODER_COPILOT_IMAGE='${CODER_COPILOT_IMAGE}'
OPENCLAW_PUB_KEY='${OPENCLAW_PUB_KEY}'

# Exec Node 配置
EXEC_NODE_CONFIG_DIR='${EXEC_NODE_CONFIG_DIR}'
OPENCLAW_GATEWAY_TLS_FINGERPRINT='${OPENCLAW_GATEWAY_TLS_FINGERPRINT}'
OPENCLAW_GATEWAY_TOKEN='${GATEWAY_TOKEN}'
EOF
"
}

deploy_openclaw_to_server() {
  build_openclaw_image_if_needed
  ensure_remote_directories
  ensure_remote_image
  ensure_gateway_token
  sync_openclaw_runtime_files
  ensure_openclaw_ssh_identity
  ensure_gateway_tls_cert
  sync_custom_extensions
}

deploy_coder_harness() {
  require_file "${COPILOT_DEPLOY_SCRIPT}"
  [ -x "${COPILOT_DEPLOY_SCRIPT}" ] || fail "Copilot 部署脚本不可执行 (${COPILOT_DEPLOY_SCRIPT})"

  substep "执行 Coder Harness 部署脚本"
  "${COPILOT_DEPLOY_SCRIPT}" \
    --remote-host "${REMOTE_HOST}" \
    --deploy-dir "${DEPLOY_DIR}" \
    --coder-harness-config-dir "${CODER_HARNESS_CONFIG_DIR}" \
    --coder-copilot-image "${CODER_COPILOT_IMAGE}"
}

copy_orchestration_files() {
  substep "同步服务编排相关文件"

  write_remote_compose_env
  scp "${SCRIPT_DIR}/docker-compose.yml" "${REMOTE_HOST}:${DEPLOY_DIR}/"
}

ensure_local_llm_network_ready() {
  substep "检查 local-llm-service 网络"
  if ! ssh "${REMOTE_HOST}" "podman network inspect local-llm-service >/dev/null 2>&1"; then
    fail "未找到 local-llm-service 网络，请先部署 LiteLLM"
  fi

  substep "检查 litellm-gateway 连通性"
  if ! ssh "${REMOTE_HOST}" "podman run --rm --network local-llm-service ${IMAGE_NAME} curl -sSf http://litellm-gateway:8081/health/liveliness >/dev/null 2>&1"; then
    fail "无法访问 litellm-gateway:8081，请检查 LiteLLM 容器和网络"
  fi
}

ensure_cdp_tunnel_user() {
  substep "创建/更新宿主机 CDP 隧道账号"
  local auth_options='restrict,port-forwarding,permitopen="127.0.0.1:9222",command="echo Tunnel Ready. Press Ctrl+C to disconnect.; read"'

  ssh -t "${REMOTE_HOST}" "
    sudo bash ${DEPLOY_DIR}/create_ssh_user.sh \
      --server-user cdp_tunnel \
      --public-key '${OPENCLAW_PUB_KEY}' \
      --auth-options '${auth_options}' \
      --nologin
  "
}

start_orchestration() {
  ensure_local_llm_network_ready
  ensure_cdp_tunnel_user

  substep "启动编排（podman-compose）"
  ssh -t "${REMOTE_HOST}" "
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    cd ${DEPLOY_DIR}
    podman-compose down > /dev/null 2>&1 || true
    podman-compose up -d
  "
}

print_success_guide() {
  echo ""
  echo "部署完成"
  echo "----------------------------------------------------"
  echo "远程主机: ${REMOTE_HOST}"
  echo "部署目录: ${DEPLOY_DIR}"
  echo "Gateway Token: ${GATEWAY_TOKEN}"
  echo "----------------------------------------------------"
  echo "访问控制面板: https://openclaw.local:18789/?token=${GATEWAY_TOKEN}"
  echo ""
  echo "若首次访问出现 pairing required，可在服务器执行:"
  echo "  podman exec -it openclaw-gateway openclaw devices list"
  echo "  podman exec -it openclaw-gateway openclaw devices approve <Request_ID>"
  echo ""
  echo "若需使用browser工具，在宿主机桌面系统的终端上运行："
  echo "  bash ${DEPLOY_DIR}/launch_chrome.sh"
  echo ""
  echo "查看网关日志:"
  echo "  podman-compose logs -f openclaw-gateway"
}

main() {
  cd "${PROJECT_ROOT}" || exit 1

  step 1 "控制量设置"
  require_file "${DOCKER_APT_SOURCES_FILE}"
  require_file "${DOCKER_NPMRC_FILE}"
  require_file "${CONFIG_JSON_PATH}"
  load_env_file_if_exists "${GLOBAL_ENV_FILE}"
  load_env_file_if_exists "${LOCAL_ENV_FILE}"
  assert_required_env_vars
  require_cmd docker
  require_cmd ssh
  require_cmd scp
  require_cmd openssl
  require_cmd keepassxc-cli
  require_cmd node

  step 2 "OpenClaw 部署文件准备"
  trap cleanup_secret_bundle EXIT
  build_keepass_secret_bundle
  resolve_openclaw_identity

  step 3 "部署 OpenClaw 版本（镜像）及相关文件到服务器"
  deploy_openclaw_to_server

  step 4 "部署 Coder Harness"
  deploy_coder_harness

  step 5 "拷贝服务编排相关文件"
  copy_orchestration_files

  step 6 "启动服务编排"
  start_orchestration

  print_success_guide
}

main "$@"
