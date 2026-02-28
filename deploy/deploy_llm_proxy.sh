#!/bin/bash
# 部署轻量级 LLM HTTP 代理服务
# 该服务在部署服务器上通过 Podman 运行，实现基于指定模型的无 key 调用。
# 所有敏感信息及配置从 .env 文件读取，保障安全。

set -euo pipefail

ENV_FILE=".env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 找不到 $ENV_FILE 文件。"
    echo "请在当前目录创建 .env，并配置 PROXY_SSH_HOST, LLM_BASE_URL, LLM_MODEL, LLM_API_KEY。"
    exit 1
fi

# 提取变量 (支持注释和空行，去除首尾引号)
PROXY_HOST=$(grep -E '^PROXY_SSH_HOST=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'\''\r' || true)
BASE_URL=$(grep -E '^LLM_BASE_URL=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'\''\r' || true)
MODEL=$(grep -E '^LLM_MODEL=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'\''\r' || true)
API_KEY=$(grep -E '^LLM_API_KEY=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'\''\r' || true)

if [[ -z "$PROXY_HOST" || -z "$BASE_URL" || -z "$MODEL" || -z "$API_KEY" ]]; then
    echo "❌ $ENV_FILE 缺少必要的环境变量。"
    echo "请确保包含以下配置："
    echo "PROXY_SSH_HOST=你的SSH服务器(例如 user@ip or rmbook)"
    echo "LLM_BASE_URL=https://api.openai.com/v1"
    echo "LLM_MODEL=gpt-3.5-turbo"
    echo "LLM_API_KEY=sk-..."
    exit 1
fi

REMOTE_DIR="~/llm-proxy-deploy"
echo "🚀 准备部署 LLM Proxy 到: $PROXY_HOST ($REMOTE_DIR)"

echo "1. 创建远程部署目录..."
ssh "$PROXY_HOST" "mkdir -p $REMOTE_DIR"

echo "2. 生成代理服务代码 (Node.js)..."
# 使用 Node.js 的标准库实现轻量级 HTTP 代理，动态注入 model 和 key
ssh "$PROXY_HOST" "cat > $REMOTE_DIR/proxy.js" << 'EOF'
const http = require('http');
const https = require('https');

const API_KEY = process.env.API_KEY || '';
const BASE_URL = process.env.BASE_URL || '';
const MODEL = process.env.MODEL || '';

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  let body = [];
  req.on('data', chunk => body.push(chunk));
  req.on('end', () => {
    let payload = Buffer.concat(body);
    if (req.method === 'POST') {
      try {
        let json = JSON.parse(payload.toString('utf8'));
        // 强制注入环境变量中指定的模型，实现无需客户端提供模型
        if (MODEL) {
            json.model = MODEL;
        }
        payload = Buffer.from(JSON.stringify(json), 'utf8');
      } catch (e) {
        // 非 JSON 或解析错误时忽略，继续原样转发
      }
    }

    let targetUrlString = BASE_URL.replace(/\/$/, '') + (req.url === '/' ? '' : req.url);
    if (!BASE_URL) {
      targetUrlString = "https://api.openai.com" + req.url;
    }
    
    let targetUrl;
    try {
        targetUrl = new URL(targetUrlString);
    } catch(e) {
        res.writeHead(400);
        res.end(JSON.stringify({error: "Invalid BASE_URL configured."}));
        return;
    }

    const isHttps = targetUrl.protocol === 'https:';
    const requestModule = isHttps ? https : http;

    const headers = { ...req.headers };
    headers['host'] = targetUrl.host;
    if (API_KEY) {
        headers['authorization'] = `Bearer ${API_KEY}`;
    }
    headers['content-length'] = payload.length.toString();
    
    // 移除 connection header 等可能干扰代理的头
    delete headers['connection'];

    const options = {
      method: req.method,
      headers: headers
    };
    
    const clientReq = requestModule.request(targetUrl, options, (clientRes) => {
      // 保留 CORS 头，且支持流式响应传递（适配 LLM Stream 功能）
      clientRes.headers['Access-Control-Allow-Origin'] = '*';
      res.writeHead(clientRes.statusCode, clientRes.headers);
      clientRes.pipe(res);
    });
    
    clientReq.on('error', (e) => {
      console.error('Proxy Forward Error:', e);
      if (!res.headersSent) {
          res.writeHead(502);
          res.end(JSON.stringify({error: "Bad Gateway", details: e.message}));
      }
    });

    clientReq.write(payload);
    clientReq.end();
  });
});

process.on('uncaughtException', (err) => {
  console.error('Uncaught Exception:', err);
});

const port = process.env.PORT || 8080;
server.listen(port, () => {
  console.log(`[LLM Proxy] Listening on port ${port}, forwarding to ${BASE_URL || 'openai'} using model ${MODEL}`);
});
EOF

echo "3. 生成 docker-compose.yml..."
ssh "$PROXY_HOST" "cat > $REMOTE_DIR/docker-compose.yml" << EOF
version: '3.8'
services:
  llm-proxy:
    image: node:20-alpine
    container_name: llm-proxy
    restart: always
    ports:
      - "8080:8080"
    volumes:
      - ./proxy.js:/app/proxy.js
    working_dir: /app
    environment:
      - BASE_URL=${BASE_URL}
      - MODEL=${MODEL}
      - API_KEY=${API_KEY}
    command: node proxy.js
EOF

echo "4. 部署与启动服务 (自动检查与幂等更新) ..."
# 使用 podman-compose up -d，如果已部署则仅在配置或代码变动时自动重新创建，并加上 --force-recreate 保证 proxy.js 被载入
ssh -t "$PROXY_HOST" "
  cd $REMOTE_DIR
  # 确保最新的环境镜像存在
  podman-compose pull node:20-alpine || true
  podman-compose up -d --force-recreate llm-proxy
"

echo ""
echo "🎉 LLM Proxy 部署完成！"
echo "----------------------------------------------------"
echo "🖥️  远程主机: ${PROXY_HOST}"
echo "📁 部署目录: ${REMOTE_DIR}"
echo "🌐 代理使用地址: http://${PROXY_HOST}:8080"
echo "✨ API Key: <客户端无需提供，代理自动注入>"
echo "✨ 模型名称: <客户端无需提供，代理自动注入 ${MODEL}>"
echo "----------------------------------------------------"
echo "如需查看运行日志，可执行："
echo "  ssh ${PROXY_HOST} 'cd ${REMOTE_DIR} && podman-compose logs -f llm-proxy'"
