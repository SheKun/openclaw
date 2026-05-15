# OpenClaw 定制部署说明

> **OpenClaw 基线版本**：`v2026.5.4`
>
> 本文档记录了对 OpenClaw 基线版本的定制、以容器方式部署到服务器的部署文件和部署方法。

---

## 目录

- [源码定制](#源码定制)
  - [Dockerfile 构建阶段调整](#dockerfile-构建阶段调整)
  - [仓库工作区配置](#仓库工作区配置)
  - [OpenClaw 插件定制](#openclaw-插件定制)
    - [guidance 插件全局注入](#guidance-插件全局注入)
    - [browser 导航超时可配置化](#browser-导航超时可配置化)
  - [跟进上游版本指南](#跟进上游版本指南)
- [部署文件](#部署文件)
- [服务器配置](#服务器配置)
- [部署架构](#部署架构)
  - [服务组成](#服务组成)
  - [网络拓扑](#网络拓扑)
    - [OpenClaw 访问这些服务的方式](#openclaw-访问这些服务的方式)
    - [SSH 密钥](#ssh-密钥)
  - [环境变量](#环境变量)
- [部署流程](#部署流程)
  - [一键部署 OpenClaw](#一键部署-openclaw)
  - [首次访问与设备配对](#首次访问与设备配对)
  - [OpenClaw 插件安装](#openclaw-插件安装)

---

## 源码定制

以下是对基线做出的**功能性**修改。跟进上游版本时需确认这些变更是否已被合并，或需要重新应用。

### Dockerfile 构建阶段调整

**涉及文件**：

- `Dockerfile`
- `scripts/lib/docker-build.sh`
- `docs/install/docker.md`
- `deploy/buildkit/debian.sources`
- `deploy/buildkit/npmrc`

**变更内容**：

- 将 `OPENCLAW_DOCKER_APT_PACKAGES` 安装步骤移到构建的最后阶段，使得后续在镜像中新增小工具时避免执行不必要的构建步骤。
- 新增 `OPENCLAW_DOCKER_JS_PACKAGES` build-arg，在主镜像中支持通过 `npm install -g` 预装全局 JS 工具（如 skill 依赖的 CLI 工具）。
- 浏览器安装后自动将 Chromium 可执行路径写入 `/app/.env`：`CHROMIUM_EXECUTABLE_PATH=<path>`，供 browser 插件直接读取。
- 支持通过 BuildKit secret 注入自定义 apt 源与 npm 源：
  - `OPENCLAW_DOCKER_APT_SOURCES_FILE` -> `openclaw_debian_sources`
  - `OPENCLAW_DOCKER_NPMRC_FILE` -> `openclaw_npmrc`
- 在依赖安装、corepack 准备、apt 安装等关键步骤统一读取上述 secret，便于在受限网络环境下复用镜像站配置。

### 仓库工作区配置

**涉及文件**：

- `.gitignore`：Git 忽略规则。
- `.dockerignore`：Docker 构建上下文忽略规则。
- `.github/labeler.yml`：PR 自动标签规则。

**变更内容**：

- `.gitignore`：添加 `openclaw.code-workspace`，避免本地 VS Code 工作区文件被误提交。
- `.dockerignore`：补充排除一批构建无关文件，包括 IDE 配置（`.vscode/`、`.github/`）、部署脚本（`deploy/`、`fly.toml`、`docker-compose.yml` 等）和文档（`ARCHITECTURE.md`），减小构建上下文体积。
- `.github/labeler.yml`：添加 `extensions: guidance` 标签规则，使 PR 涉及 `extensions/guidance/` 时自动打标签。

### OpenClaw 插件定制

#### guidance 插件全局注入

**实现原理**：

- 从 `plugins.entries.guidance.config.files` 配置的文件列表中读取 Markdown 内容。
- 通过 `registerContextEngine("guidance")` 将内容注入每次对话的 system prompt addition。
- 文件路径基于 `plugins.entries.guidance.config.rootDir` 解析（默认为 OpenClaw 配置目录），支持相对路径与绝对路径，但必须位于 `rootDir` 下（通过 `openFileWithinRoot` 安全校验）。
- 当前配置：`rootDir="/workspaces/shared"`，注入文件：`AGENTS.md`、`TOOLS.md`、`SOUL.md`、`USER.md`。
- 通过 `plugins.slots.contextEngine: "guidance"` 激活为默认上下文引擎。

#### browser 导航超时可配置化

**涉及文件**：

- `extensions/browser/src/browser-tool.ts`：browser 工具对外暴露的 CLI/ACP 接口定义。
- `extensions/browser/src/browser/client-actions-core.ts`：browser server HTTP 客户端，封装导航等操作请求。
- `extensions/browser/src/browser/routes/agent.snapshot.ts`：browser server 端路由，处理导航 + 快照请求。
- `extensions/browser/src/browser/cdp.test.ts`：CDP 连接单元测试。
- `extensions/browser/src/browser/routes/agent.snapshot.test.ts`：agent snapshot 路由单元测试。

**动机**：解决 agent 连续调用 browser 工具时，打开较大页面超时导致的竞争问题（参见提交 `08bc3770a0`、`d5bf4144c1`）。

**变更内容**：

- `browser-tool.ts`：`navigate` 命令新增 `timeoutMs` 参数（默认 25000 ms），并通过 proxy 请求体传递给 browser server。
- `client-actions-core.ts`：`browserNavigate` 函数新增 `timeoutMs` 可选参数；fetch 超时设为 `requestedTimeout + 5000 ms`（留出缓冲）。
- `routes/agent.snapshot.ts`：从请求体中解析 `timeoutMs`，透传给 CDP 导航调用。
- `cdp.test.ts`：所有 `createTargetViaCdp` 调用补充 `ssrfPolicy: { allowPrivateNetwork: true }`，使测试能连接 localhost CDP 端点。
- `agent.snapshot.test.ts`：在 `listTabs` mock 的首次返回中补充第二个 tab，匹配 `resolveTargetIdAfterNavigate` 更新后的行为。

### 跟进上游版本指南

1. 将新版本 tag 合并到本分支：`git fetch upstream && git merge v<new-version>`。
2. 解决冲突，并特别关注源码定制在新的基线上是否仍然适用或必要（新基线已做了类似修订，优先采用基线的实现）；如果仍必要则重新应用，否则报告并询问用户如何处理。
3. 运行 `pnpm build` 确认编译通过，运行 `pnpm test` 确认测试无回归。
4. 更新本文档，包括顶部的**基线版本**标注。

---

## 部署文件

```text
deploy/
├── AGENTS.md                   # 本文档
├── .env                        # 本地环境变量，包含所有密钥（不入库，见下方变量说明）
├── docker-compose.yml          # 定制化 Compose 编排文件
├── openclaw_conf.json          # OpenClaw 主配置（agents、channels、models、plugins）
├── exec-approvals.json         # Exec Node 与 Gateway 共享执行审批配置
├── start-gateway.sh            # Gateway 容器启动包装脚本
├── exec_node_entry.sh          # Exec Node 容器入口脚本
├── keepassxc-vault.sh          # Keepass secret provider 工具脚本
├── deploy_openclaw.sh          # 本地构建 + SSH 远程部署主脚本
├── create_ssh_user.sh          # SSH 用户初始化工具（创建 cdp_tunnel、coder-copilot 等系统用户）
├── launch_chrome.sh            # 宿主机 Chrome CDP 启动脚本（部署后手动运行）
├── buildkit/                   # BuildKit secret 配置（镜像源）
│   ├── debian.sources
│   └── npmrc
├── coding_harness/
│   └── copilot/                # GitHub Copilot ACP Harness 镜像定义
│       ├── Dockerfile
│       ├── deploy_copilot.sh   # Copilot Harness 独立部署脚本（被主部署脚本调用）
│       ├── coder_entry.sh      # Harness 容器入口脚本
│       ├── coder_acp_cmd.sh    # 配套 ACP 远程调用命令脚本（供 ACP client 使用）
│       └── sshd_config         # 安全加固的 SSH 服务配置
└── myextensions/
    └── guidance/               # 自定义全局规则注入插件
        ├── index.ts
        ├── index.test.ts
        ├── openclaw.plugin.json
        └── package.json
```

---

## 服务器配置

- 操作系统：Ubuntu 桌面版。
- 必备软件：
  1. Chrome：提供浏览器 CDP 服务。
  2. Podman 与 podman-compose：运行容器。

### openclaw CLI

为了方便在宿主机上，运行gateway容器中的OpenClaw CLI，在.bashrc中加入了如下配置：

```
openclaw() {
  podman exec -it openclaw-gateway openclaw "$@"
}
```

---

## 部署架构

### 服务组成

本部署除了 OpenClaw 本体，还依赖同编排内服务和编排外服务。按运行位置可分为两类。

**1) 同一编排文件中的内部服务（`deploy/docker-compose.yml`）**

| 服务                 | 容器名             | 说明                                                                      |
| -------------------- | ------------------ | ------------------------------------------------------------------------- |
| `openclaw-gateway`   | openclaw-gateway   | OpenClaw 主网关，承载所有 agent 运行时                                    |
| `openclaw-exec-node` | openclaw-exec-node | 代码执行节点，连接 Gateway 并复用同一套镜像与工具链                       |
| `coder-copilot`      | coder-copilot      | GitHub Copilot ACP Harness，通过 SSH 向 gateway 暴露 `copilot` 编码 agent |

**2) 编排外的外部服务（但被 OpenClaw 依赖）**

| 服务                                  | 所在位置                              | 作用                                      |
| ------------------------------------- | ------------------------------------- | ----------------------------------------- |
| `litellm-gateway`                     | 外部 Compose 网络 `local-llm-service` | 提供统一模型推理入口（OpenAI 兼容接口）   |
| 宿主机 Chrome CDP (`172.17.0.1:9222`) | 部署主机                              | 提供 browser 插件可复用的宿主机浏览器会话 |
| GitHub / 飞书等公网端点               | 公网                                  | Git 拉取、Copilot 鉴权、飞书收发消息等    |

### 网络拓扑

- `openclaw-gateway` 同时加入三个网络：
  - `openclaw-internal`：与 `coder-copilot` 、`openclaw-exec-node`通信（内部隔离网段）。
  - `local-llm-service`：访问编排外的 `litellm-gateway`。
  - 宿主机默认容器网络（bridge）：用于访问公网端点，并作为到 `172.17.0.1:9222` 的宿主机侧可达路径。
- `coder-copilot` 、`openclaw-exec-node`加入 `openclaw-internal`，为 gateway 提供服务。

网络拓扑如下图所示：

```text
     +---------------------+
     | openclaw-exec-node  |
     | (exec runtime)      |
     +---------------------+
                | # attach
                |
          +------------------------------+      +------------------------------+
          | Network: openclaw-internal   |      | Network: local-llm-service   |
          +------------------------------+      +------------------------------+
                       | # attach    | # attach    | # attach    | # attach
                       |             |             |             |
             +----------------+  +------------------+      +----------------+
             | coder-copilot  |  | openclaw-gateway |      | litellm-gateway|
             | (ACP harness)  |  | (core runtime)   |      | (:8081)        |
             +----------------+  +------------------+      +----------------+
                                   | # attach
                                   |
          +-----------------------------------------------+
          | Network: host default container network       |
          | (podman/docker bridge)                        |
          +-----------------------------------------------+
                                | # attach
                                |
                      +--------------------------------+
                      | Host Chrome CDP                |
                      | 172.17.0.1:9222                |
                      +--------------------------------+

Dependency arrows (依赖服务 -> 被依赖服务):

openclaw-gateway  ----------SSH(ACPx/coder_acp_cmd.sh)----------> coder-copilot
openclaw-gateway  ----------HTTP(baseUrl /v1)-------------------> litellm-gateway
openclaw-gateway  ----------SSH tunnel(cdp_tunnel, 9222)-------> Host Chrome CDP (172.17.0.1:9222)
openclaw-exec-node --------HTTPS/WSS----------------------------> openclaw-gateway
openclaw-gateway  ----------HTTPS/WebSocket outbound-----------> GitHub / Feishu / Others
```

#### OpenClaw 访问这些服务的方式

- 访问 `coder-copilot`：
  - 在 gateway 容器内通过 `coder_acp_cmd.sh` 执行 `ssh coder-copilot ...`。
  - `~/.ssh/config` 中启用 SSH 连接复用（`ControlMaster/ControlPath/ControlPersist`），降低 ACP 多次调用开销。
- 访问模型服务 `litellm-gateway`：
  - `openclaw_conf.json` 中 provider `litellm.baseUrl=http://litellm-gateway:8081/v1`。
  - 因为 gateway 连接在 `local-llm-service` 网络上，可直接通过服务名解析访问。
- 访问 `openclaw-exec-node`：
  - `openclaw-exec-node` 容器主动注册为OpenClaw的一个node
  - 读取 `OPENCLAW_GATEWAY_TOKEN` 与 `OPENCLAW_GATEWAY_TLS_FINGERPRINT`
- 访问宿主机 Chrome CDP：
  - `start-gateway.sh` 启动时建立 SSH 隧道账号 `cdp_tunnel`，将容器内 `127.0.0.1:9222` 转发到宿主机 `172.17.0.1:9222`。
  - browser 插件随后通过本地 `9222` 访问到宿主机 Chrome 调试端口。
- 访问公网服务（飞书 / GitHub 等）：
  - 通过容器默认出口网络直连公网。
  - 凭据由 `deploy/.env` 注入（如飞书 app 凭据、Copilot token、模型 key）。

#### SSH 密钥

部署脚本为 gateway 容器生成密钥对 auth，并将其配置为访问 github.com、cdp_tunnel 和 coder-copilot 的公共密钥。

### 环境变量

部署脚本会在部署服务器侧写入三类运行时配置：

- `${DEPLOY_DIR}/.env`：compose 变量与容器运行参数（镜像 tag、Gateway Token、日志等级、目录挂载等）。
- `${OPENCLAW_CONFIG_DIR}/.env`：OpenClaw 明文配置（例如 Feishu App ID）。
- `${DEPLOY_DIR}/secrets/openclaw-secrets.kdbx` 与 `${DEPLOY_DIR}/secrets/openclaw-secrets.pass`：Keepass 密钥库与解锁密码文件，供 secret provider 读取敏感值（例如 app secret、API key）。

### 共享挂载

主要为了服务化和安全考虑，`coder harness` 和 `exec` 等工具执行与 `openclaw-gateway` 解耦，由独立容器提供服务。为了让跨容器协作时路径无需转换，关键目录在多个容器中保持相同挂载路径。

#### `openclaw-gateway` & `coder-copilot`

- 项目工作目录 `${DEPLOY_DIR}/output/projects` -> `/projects`：gateway 将 `/projects` 设置为 ACP agent coder 的工作目录(CWD)，因此 `/projects` 需要在两个容器中都存在。

#### `openclaw-gateway` & `openclaw-exec-node`

- `${OPENCLAW_CONFIG_DIR}/.ssh` -> `/home/node/.ssh`：共享同一套 SSH 身份与 host 配置，保证 gateway/exec-node 访问策略一致，例如，远端git仓库
- `${DEPLOY_DIR}/workspaces` -> `/workspaces`：agent 工作目录的根目录，gateway 配置需要引用，同时 agent 也需要通过 `exec` 工具访问
- 容器卷 `apt_archives` -> `/var/cache/apt/archives/`：缓存 apt 包下载，加速 exec-node 依赖安装，gateway 和 agent（通过 `exec`）都可能触发 `apt install`
- 容器卷 `npm_archives` -> `/home/node/.npm`：缓存 npm 包元数据与离线存储，加速依赖安装和离线构建，gateway 和 agent（通过 `exec`）都可能触发 `npm install`

---

## 部署流程

### 一键部署 OpenClaw

```bash
# 默认部署到 rmbook 主机
bash deploy/deploy_openclaw.sh

# 指定目标主机
bash deploy/deploy_openclaw.sh my-server
```

主要逻辑：

1. 加载 `../.env`（全局）和 `deploy/.env`（本地）环境变量。
2. 生成 Keepass 密钥库并写入部署所需敏感配置。
3. 从 `package.json` 读取版本号，拼装镜像 tag（当前脚本使用固定构建后缀：`krepus.com/openclaw:<version>-build202605091410`）。
4. 构建 OpenClaw 主镜像（传递 `OPENCLAW_EXTENSIONS`、`OPENCLAW_DOCKER_JS_PACKAGES`、`OPENCLAW_DOCKER_APT_PACKAGES` 等 build-arg）。
5. 构建 `coder-copilot` Harness 镜像（`krepus.com/coder-copilot:<copilot_version>`）。
6. 使用 `docker save | ssh ... podman load` 将镜像直接导入目标主机。
7. 同步 compose、入口脚本、OpenClaw 配置、审批配置、Keepass 密钥库及自定义插件包。
8. 在目标主机生成或复用 Gateway Token 与 TLS 证书，计算并注入 TLS 指纹给 Exec Node。
9. 检查 `local-llm-service` 网络与 `litellm-gateway` 健康状态。
10. 执行 `podman-compose down && podman-compose up -d` 拉起服务。

注意：

- 部署脚本默认目标主机为 `rmbook`，可通过参数覆盖。
- 脚本要求本地具备 `docker`、`pnpm`、`keepassxc-cli`、`node`，远程具备 `podman` 与 `podman-compose`。

### 首次访问与设备配对

部署完成后，推荐通过 HTTPS 访问控制台并完成设备配对：

1. 本地 hosts 增加：`<服务器IP> openclaw.local`。
2. 首次访问：`https://openclaw.local:18789/?token=<OPENCLAW_GATEWAY_TOKEN>`。
3. 若提示 `pairing required`，在服务器执行：

```bash
podman exec -it openclaw-gateway openclaw devices list
podman exec -it openclaw-gateway openclaw devices approve <Request_ID>
```

4. 批准后去掉 `?token=...` 刷新访问。

### OpenClaw 插件安装

插件分为 `预装`、`选装 tgz`、`按名称安装内置插件` 三类：

- 预装插件连同其依赖库将直接打包进 OpenClaw 镜像，详见 `Dockerfile`。
- 选装 tgz 插件由部署脚本编译并通过 `pnpm pack` 打包到 `deploy/myextensions/dist`，再上传到远程 `${DEPLOY_DIR}/myextensions`。
- `start-gateway.sh` 会自动扫描 `/home/node/.openclaw/extensions/*.tgz`，执行 `openclaw plugins install` 和 `openclaw plugins enable`。
- 通过 `BUNDLED_PLUGINS_TO_INSTALL` 指定的插件名称（例如 `memory-wiki`）会在容器启动时按名称安装并启用。

---
