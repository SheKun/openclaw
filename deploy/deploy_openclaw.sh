#!/bin/bash
# 依照 OpenClaw Docker 文档步骤：本地构造镜像，导出并通过 SSH 部署到远程服务器
# 目标主机: 默认为 rmbook，可通过第一个参数指定

# 设置脚本在遇到错误 (-e)、未定义变量 (-u) 或管道命令失败 (-o pipefail) 时立即退出
set -euo pipefail

# 获取脚本所在目录并切换到项目根目录，以确保相对路径执行正确
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
COPILOT_HARNESS_DIR="${SCRIPT_DIR}/coding_harness/copilot"
DOCKER_BUILDKIT_CONFIG_DIR="${SCRIPT_DIR}/buildkit"
DOCKER_APT_SOURCES_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/debian.sources"
DOCKER_NPMRC_FILE="${DOCKER_BUILDKIT_CONFIG_DIR}/npmrc"
cd "${PROJECT_ROOT}" || exit 1

for required_file in "$DOCKER_APT_SOURCES_FILE" "$DOCKER_NPMRC_FILE"; do
  if [ ! -f "$required_file" ]; then
    echo "错误: 未找到 BuildKit 镜像源配置文件 (${required_file})"
    exit 1
  fi
done

DOCKER_BUILD_SECRET_ARGS=(
  --secret "id=openclaw_debian_sources,src=${DOCKER_APT_SOURCES_FILE}"
  --secret "id=openclaw_npmrc,src=${DOCKER_NPMRC_FILE}"
)

echo "0. 配置环境变量 ..."
# 加载环境变量
GLOBAL_ENV_FILE="${PROJECT_ROOT}/../.env"
LOCAL_ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$GLOBAL_ENV_FILE" ]; then
  echo "加载全局 .env 文件从: ${GLOBAL_ENV_FILE}"
  set -a; source <(sed 's/\r//' "$GLOBAL_ENV_FILE"); set +a
fi
if [ -f "$LOCAL_ENV_FILE" ]; then
  echo "加载本地 .env 文件从: ${LOCAL_ENV_FILE}"
  set -a; source <(sed 's/\r//' "$LOCAL_ENV_FILE"); set +a
fi

# openclaw 服务配置
OPENCLAW_VERSION=$(grep -m1 '"version":' package.json | awk -F'"' '{print $4}')
if [ -z "$OPENCLAW_VERSION" ]; then
  echo "无法从 package.json 获取版本号！"
  exit 1
fi
VERSION="${OPENCLAW_VERSION}-build202605091851"
IMAGE_NAME="krepus.com/openclaw:${VERSION}"
OPENCLAW_CONFIG_DIR="~/.openclaw"

CONFIG_JSON_PATH="${SCRIPT_DIR}/openclaw_conf.json"
if [ ! -f "$CONFIG_JSON_PATH" ]; then
  echo "错误: 未找到配置文件 (${CONFIG_JSON_PATH})"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "错误: 需要 node 命令来解析默认 agent，请先安装 Node.js。"
  exit 1
fi

DEFAULT_AGENT_ID=$(node -e '
const fs = require("node:fs");
const cfgPath = process.argv[1];
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
const list = Array.isArray(cfg?.agents?.list) ? cfg.agents.list : [];
const defaultAgent = list.find((entry) => entry && entry.default === true);
const fallbackAgent = list[0];
const id = (defaultAgent?.id || fallbackAgent?.id || "main").toString().trim();
process.stdout.write(id || "main");
' "$CONFIG_JSON_PATH")

DEFAULT_AGENT_DIR="${OPENCLAW_CONFIG_DIR}/agents/${DEFAULT_AGENT_ID}/agent"
echo "=> 从配置解析默认 Agent: ${DEFAULT_AGENT_ID}"
echo "=> 将设置 OPENCLAW_AGENT_DIR=${DEFAULT_AGENT_DIR}"

# Copilot Harness 服务配置
COPILOT_VERSION="1.0.38" # 这里可以指定一个固定版本，或者留空以自动查询最新版本
if [ -z "$COPILOT_VERSION" ]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "错误: 需要 npm 命令来查询 Copilot 最新版本，请先安装 npm。"
    exit 1
  fi
  COPILOT_VERSION=$(npm view @github/copilot version 2>/dev/null | tr -d '[:space:]')
  if [ -z "$COPILOT_VERSION" ]; then
    echo "错误: 无法获取 @github/copilot 的最新版本号。"
    exit 1
  fi
fi
COPILOT_HARNESS_BASE_IMAGE="node:22-bookworm-slim"
CODER_COPILOT_IMAGE="krepus.com/coder-copilot:${COPILOT_VERSION}"
CODER_HARNESS_CONFIG_DIR="~/.coder-harness"
echo "=> 检测到最新 Copilot CLI 版本: ${COPILOT_VERSION}"
echo "=> 将构建并部署 Harness 镜像: ${CODER_COPILOT_IMAGE}"

COPILOT_MODEL="deepseek-v4-pro"
COPILOT_PROVIDER_MAX_PROMPT_TOKEN=1000000
COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=393216
BUNDLED_PLUGINS_TO_INSTALL=""

# 远程部署配置
REMOTE_HOST="${1:-rmbook}"
DEPLOY_DIR="~/openclaw-deploy"


echo "1. 检查是否存在镜像 ${IMAGE_NAME} ..."
if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "镜像 ${IMAGE_NAME} 已存在，跳过本地构建。"
else
  echo "镜像 ${IMAGE_NAME} 不存在，开始按照文档步骤本地构造 OpenClaw 镜像 (docker build) ..."
  # 关闭 provenance 来源证明生成，彻底解决较老版本 podman 3.4 导入 tar 包后 tag 变成 localhost 的问题
  # 使用 --progress=plain 保存完整构建日志，便于事后排查缓存失效。
  BUILD_LOG="/tmp/openclaw-build-${IMAGE_NAME//[\/:]/_}.log"
  echo "=> 构建日志将保存至: ${BUILD_LOG}"
  DOCKER_BUILDKIT=1 docker build --progress=plain --provenance=false \
    "${DOCKER_BUILD_SECRET_ARGS[@]}" \
    --build-arg "OPENCLAW_EXTENSIONS=browser lobster open-prose llm-task acpx document-extract memory-core active-memory feishu perplexity" \
    --build-arg "OPENCLAW_DOCKER_JS_PACKAGES=@clawdbot/lobster clawhub" \
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=keepassxc jq ripgrep openssh-client" \
    -t "${IMAGE_NAME}" -f Dockerfile . 2>&1 | tee "${BUILD_LOG}"
fi

echo "2. 检查是否存在镜像 ${CODER_COPILOT_IMAGE} ..."
if docker image inspect "${CODER_COPILOT_IMAGE}" >/dev/null 2>&1; then
  echo "镜像 ${CODER_COPILOT_IMAGE} 已存在，跳过本地构建。"
else
  echo "镜像 ${CODER_COPILOT_IMAGE} 不存在，开始构建 Copilot Harness 镜像 ..."
  DOCKER_BUILDKIT=1 docker build --provenance=false \
    "${DOCKER_BUILD_SECRET_ARGS[@]}" \
    --build-arg "BASE_IMAGE=${COPILOT_HARNESS_BASE_IMAGE}" \
    --build-arg "COPILOT_VERSION=${COPILOT_VERSION}" \
    --secret id=GH_TOKEN,env=COPILOT_GITHUB_TOKEN \
    -t "${CODER_COPILOT_IMAGE}" \
    -f "${COPILOT_HARNESS_DIR}/Dockerfile" "${COPILOT_HARNESS_DIR}"
fi

echo "3. 将镜像导入 ${REMOTE_HOST} (podman save & load) ..."
if ssh "$REMOTE_HOST" "podman image inspect ${IMAGE_NAME} >/dev/null 2>&1"; then
  echo "远程主机 ${REMOTE_HOST} 已存在镜像 ${IMAGE_NAME}，跳过导入步骤。"
else
  echo "远程主机缺少该镜像，将其导出并通过 ssh 的标准输入直接载入远程节点 ..."
  docker save "${IMAGE_NAME}" | ssh "$REMOTE_HOST" "podman load"
fi

echo "4. 将 Copilot Harness 镜像导入 ${REMOTE_HOST} (podman save & load) ..."
if ssh "$REMOTE_HOST" "podman image inspect ${CODER_COPILOT_IMAGE} >/dev/null 2>&1"; then
  echo "远程主机 ${REMOTE_HOST} 已存在镜像 ${CODER_COPILOT_IMAGE}，跳过导入步骤。"
else
  echo "远程主机缺少该镜像，将其导出并通过 ssh 的标准输入直接载入远程节点 ..."
  docker save "${CODER_COPILOT_IMAGE}" | ssh "$REMOTE_HOST" "podman load"
fi

echo "5. 准备部署文件 ..."
ssh "$REMOTE_HOST" "mkdir -p ${DEPLOY_DIR}"

# 从 KeePass 密码库中读取密钥，生成 secret_file.json
echo "从 KeePass 密码库中加载密钥..."
KEEPASS_FILE="${SCRIPT_DIR}/../../keepass.kdbx"
if [ ! -f "$KEEPASS_FILE" ]; then
  echo "错误: 未找到 KeePass 密码库文件 (${KEEPASS_FILE})"
  exit 1
fi

FEISHU_APP_STEWARD_SLOT_PATH="飞书/家庭/FEISHU_APP_STEWARD"
FEISHU_APP_PLANNER_SLOT_PATH="飞书/家庭/FEISHU_APP_PLANNER"
FEISHU_APP_CODER_SLOT_PATH="飞书/家庭/FEISHU_APP_CODER"

# 辅助函数: 从 KeePass 条目读取 UserName 属性（对应 AppID）
kp_username() {
  echo "${KEEPASS_PASSWORD}" | keepassxc-cli show -q -a UserName "$KEEPASS_FILE" "$1" 2>&1
}

# 辅助函数: 从 KeePass 条目读取 Password 属性（对应 AppSecret / API Key）
kp_password() {
  echo "${KEEPASS_PASSWORD}" | keepassxc-cli show -q -a Password "$KEEPASS_FILE" "$1" 2>&1
}

FEISHU_APP_ID_STEWARD=$(kp_username "${FEISHU_APP_STEWARD_SLOT_PATH}")
FEISHU_APP_SECRET_STEWARD=$(kp_password "${FEISHU_APP_STEWARD_SLOT_PATH}")
FEISHU_APP_ID_CODER=$(kp_username "${FEISHU_APP_CODER_SLOT_PATH}")
FEISHU_APP_SECRET_CODER=$(kp_password "${FEISHU_APP_CODER_SLOT_PATH}")
FEISHU_APP_ID_PLANNER=$(kp_username "${FEISHU_APP_PLANNER_SLOT_PATH}")
FEISHU_APP_SECRET_PLANNER=$(kp_password "${FEISHU_APP_PLANNER_SLOT_PATH}")

echo "6. 在远程服务器初始化与启动服务 ..."
# 检查是否已有 .env 并提取 Gateway Token
EXISTING_TOKEN=$(ssh "$REMOTE_HOST" "if [ -f ${DEPLOY_DIR}/.env ]; then grep '^OPENCLAW_GATEWAY_TOKEN=' ${DEPLOY_DIR}/.env | cut -d'=' -f2 | tr -d '\\\"'; fi" || true)

if [ -n "$EXISTING_TOKEN" ]; then
  echo "=> 发现已存在的 Gateway Token，将继续使用该 Token。"
  GATEWAY_TOKEN="$EXISTING_TOKEN"
else
  echo "=> 生成新的 Gateway Token ..."
  GATEWAY_TOKEN=$(openssl rand -hex 32)
fi

echo "=> 创建部署目录 ..."
ssh "$REMOTE_HOST" "mkdir -p ${DEPLOY_DIR}"

echo "=> 复制部署文件到远程服务器 ..."
scp "${SCRIPT_DIR}/docker-compose.yml" "$REMOTE_HOST:${DEPLOY_DIR}/"
scp "${SCRIPT_DIR}/coding_harness/copilot/coder_entry.sh" "$REMOTE_HOST:${DEPLOY_DIR}/coder_entry.sh"
scp "${SCRIPT_DIR}/start-gateway.sh" "$REMOTE_HOST:${DEPLOY_DIR}/start-gateway.sh"
scp "${SCRIPT_DIR}/create_ssh_user.sh" "$REMOTE_HOST:${DEPLOY_DIR}/create_ssh_user.sh"
scp "${SCRIPT_DIR}/coding_harness/copilot/coder_acp_cmd.sh" "$REMOTE_HOST:${DEPLOY_DIR}/coder_acp_cmd.sh"
ssh "$REMOTE_HOST" "chmod +x ${DEPLOY_DIR}/*.sh"

echo "=> 检查coder harness配置目录 ${CODER_HARNESS_CONFIG_DIR} ..."
ssh "$REMOTE_HOST" "
  echo '   => 创建 coder harness 配置目录 ...'
  mkdir -p ${CODER_HARNESS_CONFIG_DIR}
  mkdir -p ${CODER_HARNESS_CONFIG_DIR}/.ssh
  mkdir -p ${CODER_HARNESS_CONFIG_DIR}/.copilot
"
echo "=> 复制 coder harness 配置文件到 ${CODER_HARNESS_CONFIG_DIR} ..."
scp ${COPILOT_HARNESS_DIR}/copilot-instructions.md "$REMOTE_HOST:${CODER_HARNESS_CONFIG_DIR}/copilot-instructions.md"

echo "=> 生成 SSH environment 文件 (Copilot BYOK 变量，通过卷挂载注入容器) ..."
ssh "$REMOTE_HOST" "mkdir -p ${CODER_HARNESS_CONFIG_DIR}/.ssh"
ssh "$REMOTE_HOST" "cat > ${CODER_HARNESS_CONFIG_DIR}/.ssh/environment && chmod 600 ${CODER_HARNESS_CONFIG_DIR}/.ssh/environment" <<EOF
GH_TOKEN=${COPILOT_GITHUB_TOKEN:-}
EOF

echo "=> 检查配置目录 ${OPENCLAW_CONFIG_DIR} ..."
ssh "$REMOTE_HOST" "
  echo '   => 创建配置目录并初始化 OpenClaw 配置 ...'
  mkdir -p ${OPENCLAW_CONFIG_DIR}
  mkdir -p ${OPENCLAW_CONFIG_DIR}/.ssh
  mkdir -p ${OPENCLAW_CONFIG_DIR}/.ssh/sockets
  mkdir -p ${OPENCLAW_CONFIG_DIR}/projects
  mkdir -p ${OPENCLAW_CONFIG_DIR}/wiki
"
echo "=> 复制配置文件 openclaw.json 到 ${OPENCLAW_CONFIG_DIR}/openclaw.json ..."
scp ${SCRIPT_DIR}/openclaw_conf.json "$REMOTE_HOST:${OPENCLAW_CONFIG_DIR}/openclaw.json"

echo "=> 创建openclaw认证密钥对 ..."
ssh "$REMOTE_HOST" "
  if [ ! -f ${OPENCLAW_CONFIG_DIR}/.ssh/auth ]; then
    echo '   => 生成新的认证密钥对 ...'
    ssh-keygen -t ed25519 -f ${OPENCLAW_CONFIG_DIR}/.ssh/auth -N '' -C 'openclaw' -q
  else
    echo '   => 认证密钥对已存在，跳过生成 ...'
  fi
"
OPENCLAW_PUB_KEY=$(ssh "$REMOTE_HOST" "cat ${OPENCLAW_CONFIG_DIR}/.ssh/auth.pub")
ssh "$REMOTE_HOST" "
  cat <<EOF > ${OPENCLAW_CONFIG_DIR}/.ssh/config
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

echo "=> 创建openclaw-gateway服务访问宿主机CDP调试端口的SSH隧道账号 ..."
AUTH_OPTIONS="restrict,port-forwarding,permitopen=\"127.0.0.1:9222\",command=\"echo Tunnel Ready. Press Ctrl+C to disconnect.; read\""
ssh -t "$REMOTE_HOST" "
  sudo bash ${DEPLOY_DIR}/create_ssh_user.sh \
    --server-user cdp_tunnel \
    --public-key '${OPENCLAW_PUB_KEY}' \
    --auth-options '${AUTH_OPTIONS}' \
    --nologin
"

# 统一使用 .env：既用于 compose 变量替换，也为 service environment 提供取值
echo "=> 生成 .env 文件 (compose + runtime 变量) ..."
ssh "$REMOTE_HOST" "
cat <<EOF > ${DEPLOY_DIR}/.env
OPENCLAW_IMAGE=${IMAGE_NAME}
CODER_COPILOT_IMAGE=${CODER_COPILOT_IMAGE}
OPENCLAW_CONFIG_DIR=${OPENCLAW_CONFIG_DIR}
CODER_HARNESS_CONFIG_DIR=${CODER_HARNESS_CONFIG_DIR}
OPENCLAW_AGENT_DIR=${DEFAULT_AGENT_DIR}
PI_CODING_AGENT_DIR=${DEFAULT_AGENT_DIR}
OPENCLAW_PUB_KEY='${OPENCLAW_PUB_KEY}'
OPENCLAW_TZ=${OPENCLAW_TZ:-UTC}

OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
COPILOT_GITHUB_TOKEN=${COPILOT_GITHUB_TOKEN:-}
FEISHU_APP_ID_STEWARD=${FEISHU_APP_ID_STEWARD:-}
FEISHU_APP_SECRET_STEWARD=${FEISHU_APP_SECRET_STEWARD:-}
FEISHU_APP_ID_CODER=${FEISHU_APP_ID_CODER:-}
FEISHU_APP_SECRET_CODER=${FEISHU_APP_SECRET_CODER:-}
FEISHU_APP_ID_PLANNER=${FEISHU_APP_ID_PLANNER:-}
FEISHU_APP_SECRET_PLANNER=${FEISHU_APP_SECRET_PLANNER:-}
LITELLM_API_KEY=${LITELLM_API_KEY:-}
PERPLEXITY_API_KEY=${PERPLEXITY_API_KEY:-}
AGENT_SECRET_DB_PASSWORD=${AGENT_SECRET_DB_PASSWORD:-}
BUNDLED_PLUGINS_TO_INSTALL='${BUNDLED_PLUGINS_TO_INSTALL:-}'
EOF
"

echo "=> 检查 local-llm-service 网络 ..."
if ! ssh "$REMOTE_HOST" "podman network inspect local-llm-service >/dev/null 2>&1"; then
  echo "❌ 错误: 未找到 local-llm-service 网络。请确保 LiteLLM 已正确部署并创建了该网络。"
  exit 1
fi

echo "=> 检查 litellm-gateway 是否满足连通性要求 ..."
# 使用已导入的 OpenClaw 镜像在相同网络内探测 litellm-gateway:8081
# 使用 curl 检查 LiteLLM 的健康状态
if ! ssh "$REMOTE_HOST" "podman run --rm --network local-llm-service ${IMAGE_NAME} curl -sSf http://litellm-gateway:8081/health/liveliness >/dev/null 2>&1"; then
  echo "❌ 错误: 无法访问 litellm-gateway:8081。请检查 LiteLLM 容器是否正在运行且已连接到 local-llm-service 网络。"
  exit 1
fi
echo "   => 连通性检查通过。"

echo '=> 同步自定义插件 ...'
CUSTOM_EXTENSIONS_DIR="${SCRIPT_DIR}/myextensions"
CUSTOM_EXTENSIONS=("guidance") # 这里可以添加更多自定义插件名称
CUSTOM_EXTENSIONS_ARTIFACT_DIR="${CUSTOM_EXTENSIONS_DIR}/dist"
if [ "${#CUSTOM_EXTENSIONS[@]}" -gt 0 ]; then
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "❌ 错误: 未找到 pnpm，无法编译自定义插件。"
    exit 1
  fi

  echo "   -> 编译并打包自定义插件..."
  ssh "$REMOTE_HOST" "
    mkdir -p ${DEPLOY_DIR}/myextensions && \
    find ${DEPLOY_DIR}/myextensions -mindepth 1 -maxdepth 1 -exec rm -rf {} +\
  "
  rm -rf "${CUSTOM_EXTENSIONS_ARTIFACT_DIR}"
  mkdir -p "${CUSTOM_EXTENSIONS_ARTIFACT_DIR}"
  for ext in "${CUSTOM_EXTENSIONS[@]}"; do
    EXT_SRC_DIR="${CUSTOM_EXTENSIONS_DIR}/$ext"
    if [ ! -d "$EXT_SRC_DIR" ]; then
      echo "   ⚠️ 警告: 找不到本地扩展目录 ${EXT_SRC_DIR}，跳过编译。"
      continue
    fi
    if [ ! -f "$EXT_SRC_DIR/package.json" ]; then
      echo "   ⚠️ 警告: 扩展 ${ext} 缺少 package.json，跳过编译。"
      continue
    fi

    rm -rf "$EXT_SRC_DIR/dist"
    mkdir -p "$EXT_SRC_DIR/dist"
    (
      echo "      - 编译 ${ext} -> dist"
      cd "$EXT_SRC_DIR"
      pnpm exec tsc --ignoreConfig index.ts \
        --module esnext \
        --moduleResolution bundler \
        --target es2022 \
        --outDir dist \
        --declaration false \
        --sourceMap false \
        --skipLibCheck \
        --noCheck
      PACKED=$(pnpm pack --pack-destination "${CUSTOM_EXTENSIONS_ARTIFACT_DIR}" 2>/dev/null | tail -1)
      echo "      - 同步 $(basename "$PACKED") 到远程服务器 ..."
      scp "$PACKED" "$REMOTE_HOST:${DEPLOY_DIR}/myextensions/"
    )
  done
fi

echo '=> 重新启动 openclaw-gateway 容器 ...'
ssh -t "$REMOTE_HOST" "
  export PATH=\"~/.local/bin:\$PATH\"
  cd ${DEPLOY_DIR}
  podman-compose down > /dev/null 2>&1 || true
  podman-compose up -d
"


echo ""
echo "🎉 部署完成！"
echo "----------------------------------------------------"
echo "🖥️  远程主机: ${REMOTE_HOST}"
echo "📁 部署目录: ${DEPLOY_DIR}"
echo "🔑 你的 Gateway Token: ${GATEWAY_TOKEN}"
echo "----------------------------------------------------"
echo "📝 【使用说明与帮助】"
echo ""
echo "▶ 1. 访问控制面板 (Control UI)"
echo "因为我们启用了更安全的 HTTPS 和设备认证，请按照以下步骤在你的电脑上进行配置："
echo "   a. 修改你的本地 hosts 文件 (Windows: C:\\Windows\\System32\\drivers\\etc\\hosts, Mac/Linux: /etc/hosts)"
echo "   b. 在末尾添加一行:"
echo "      <你的服务器IP> openclaw.local"
echo "   c. 在浏览器中打开以下带 Token 认证的专属链接 (用于首次设备配对):"
echo "      https://openclaw.local:18789/?token=${GATEWAY_TOKEN}"
echo "   d. 浏览器可能会提示“证书不受信任”(因为是自签名证书)，"
echo "      - Chrome/Edge: 盲打输入 thisisunsafe 即可绕过"
echo "      - 其他浏览器: 点击“高级” -> “继续前往”"
echo ""
echo "▶ 2. 批准设备配对 (仅限首次)"
echo "打开页面后如果报错“pairing required”并且页面被断开，说明设备正在等待批准。"
echo "请在服务器 (${REMOTE_HOST}) 上执行以下命令来批准你的浏览器设备："
echo "   # 查看等待配对的请求设备 (找到对应的 Request ID)"
echo "   podman exec -it openclaw-gateway openclaw devices list"
echo "   # 批准该设备的请求"
echo "   podman exec -it openclaw-gateway openclaw devices approve <Request_ID>"
echo "批准完成后，浏览器去掉 ?token=... 后缀直接刷新访问即可。"
echo ""
echo "▶ 3. 查看运行日志"
echo "如需查看网关运行日志，可执行："
echo "   podman-compose logs -f openclaw-gateway"
echo ""
echo "▶ 4. 建立 CDP 浏览器隧道 (可选)"
echo "如果你希望在宿主机上运行 Chrome 浏览器并让容器访问，请在服务器上运行："
echo "   google-chrome --remote-debugging-port=9222" 
echo "                 --user-data-dir=/tmp/openclaw-chrome"
echo "                 --remote-allow-origins=\"*\""
echo "                 --log-level=3"
echo "----------------------------------------------------"
