#!/bin/bash
# 依照 OpenClaw Docker 文档步骤：本地构造镜像，导出并通过 SSH 部署到远程服务器
# 目标主机: rmbook

# 设置脚本在遇到错误 (-e)、未定义变量 (-u) 或管道命令失败 (-o pipefail) 时立即退出
set -euo pipefail

# 获取脚本所在目录并切换到项目根目录，以确保相对路径执行正确
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# 检查本地 .env 文件是否存在，如果存在则加载环境变量
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
  # 忽略注释和空行加载环境变量
  echo "加载本地 .env 文件从: ${ENV_FILE}"
  export $(grep -v '^#' "$ENV_FILE" | grep -v '^$' | xargs)
else
  echo "警告: 未找到本地 .env 文件 (${ENV_FILE})."
fi

# 从 package.json 获取版本号
VERSION=$(grep -m1 '"version":' package.json | awk -F'"' '{print $4}')
if [ -z "$VERSION" ]; then
  echo "无法从 package.json 获取版本号！"
  exit 1
fi

IMAGE_NAME="krepus.com/openclaw:${VERSION}"
REMOTE_HOST="rmbook"
REMOTE_DIR="~/openclaw-deploy"

echo "1. 检查是否存在镜像 ${IMAGE_NAME} ..."
if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "镜像 ${IMAGE_NAME} 已存在，跳过本地构建。"
else
  echo "镜像 ${IMAGE_NAME} 不存在，开始按照文档步骤本地构造 OpenClaw 镜像 (docker build) ..."
  # 关闭 provenance 来源证明生成，彻底解决较老版本 podman 3.4 导入 tar 包后 tag 变成 localhost 的问题
  docker build --provenance=false -t "${IMAGE_NAME}" -f Dockerfile .
fi

echo "2. 将镜像导入 ${REMOTE_HOST} (podman save & load) ..."
if ssh "$REMOTE_HOST" "podman image inspect ${IMAGE_NAME} >/dev/null 2>&1"; then
  echo "远程主机 ${REMOTE_HOST} 已存在镜像 ${IMAGE_NAME}，跳过导入步骤。"
else
  echo "远程主机缺少该镜像，将其导出并通过 ssh 的标准输入直接载入远程节点 ..."
  docker save "${IMAGE_NAME}" | ssh "$REMOTE_HOST" "podman load"
fi

echo "3. 准备远程目录与 docker-compose 配置文件 ..."
ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_DIR}"
scp docker-compose.yml "$REMOTE_HOST:${REMOTE_DIR}/"
scp "${SCRIPT_DIR}/openclaw_conf.json" "$REMOTE_HOST:${REMOTE_DIR}/openclaw.json"

echo "4. 在远程服务器初始化与启动服务 ..."
# 检查是否已有 .env 并提取 Gateway Token
EXISTING_TOKEN=$(ssh "$REMOTE_HOST" "if [ -f ${REMOTE_DIR}/.env ]; then grep '^OPENCLAW_GATEWAY_TOKEN=' ${REMOTE_DIR}/.env | cut -d'=' -f2 | tr -d '\\\"'; fi" || true)

if [ -n "$EXISTING_TOKEN" ]; then
  echo "发现已存在的 Gateway Token，将继续使用该 Token。"
  GATEWAY_TOKEN="$EXISTING_TOKEN"
else
  echo "生成新的 Gateway Token ..."
  GATEWAY_TOKEN=$(openssl rand -hex 32)
fi

ssh -t "$REMOTE_HOST" "
  export PATH=\"~/.local/bin:\$PATH\"

  cd ${REMOTE_DIR}
  
  # 保存 .env 文件以保证 podman-compose up -d 可以持久化加载所需的环境变量
  cat <<EOF > .env
OPENCLAW_IMAGE=${IMAGE_NAME}
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_CONFIG_DIR=~/.openclaw
OPENCLAW_WORKSPACE_DIR=~/.openclaw/workspace
FEISHU_APP_ID=${FEISHU_APP_ID:-}
FEISHU_APP_SECRET=${FEISHU_APP_SECRET:-}
FEISHU_VERIFICATION_TOKEN=${FEISHU_VERIFICATION_TOKEN:-}
EOF
  
  # 创建绑定的目录从而防止可能产生的 root 权限写入问题
  mkdir -p ~/.openclaw/workspace
  
  echo '=> 应用默认配置 ...'
  cp ${REMOTE_DIR}/openclaw.json ~/.openclaw/openclaw.json
  
  # 设置目录权限，确保容器内非 root 用户拥有写权限
  chmod -R 777 ~/.openclaw
  
  echo '=> 重新启动/更新 openclaw-gateway 容器 ...'
  # 注意：不能只用 restart，restart 不会载入新的 .env 环境变量
  # 使用 up -d 会在配置改变时自动重建容器，让新环境变量生效
  podman-compose up -d openclaw-gateway
"

echo ""
echo "🎉 部署完成！"
echo "----------------------------------------------------"
echo "🖥️  远程主机: ${REMOTE_HOST}"
echo "📁 部署目录: ${REMOTE_DIR}"
echo "🔑 你的 Gateway Token: ${GATEWAY_TOKEN}"
echo "----------------------------------------------------"
echo "📝 【使用说明与帮助】"
echo ""
echo "▶ 1. 访问控制面板 (Control UI)"
echo "因为我们启用了更安全的 HTTPS 和设备认证，请按照以下步骤在你的电脑上进行配置："
echo "   a. 修改你的本地 hosts 文件 (Windows: C:\\Windows\\System32\\drivers\\etc\\hosts, Mac/Linux: /etc/hosts)"
echo "   b. 在末尾添加一行:"
echo "      ${REMOTE_HOST} my-openclaw.local"
echo "   c. 在浏览器中打开以下带 Token 认证的专属链接 (用于首次设备配对):"
echo "      https://my-openclaw.local:18789/?token=${GATEWAY_TOKEN}"
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
echo "----------------------------------------------------"
