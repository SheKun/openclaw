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
- 通过 `registerContextEngine` 将内容注入每次对话的 system prompt addition。
- 当前注入的文件：`workspace-shared/AGENTS.md`、`TOOLS.md`、`SOUL.md`、`USER.md`（相对于 `~/.openclaw`）。
- 通过 `plugins.slots.contextEngine: "public-guidance"` 激活为默认上下文引擎。

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
├── start-gateway.sh            # Gateway 容器启动包装脚本
├── deploy_openclaw.sh          # 本地构建 + SSH 远程部署脚本
├── create_ssh_user.sh          # SSH 用户初始化工具（被 coder-copilot 容器调用）
├── buildkit/                   # BuildKit secret 配置（镜像源）
│   ├── debian.sources
│   └── npmrc
├── coding_harness/
│   └── copilot/                # GitHub Copilot ACP Harness 镜像定义
│       ├── Dockerfile
│       ├── coder_entry.sh      # Harness 容器入口脚本
│       ├── coder_acp_cmd.sh    # 配套 ACP 远程调用命令脚本（供 ACP client 使用，例如 openclaw gateway）
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

---

## 部署架构

### 服务组成

本部署除了 OpenClaw 本体，还依赖同编排内服务和编排外服务。按运行位置可分为两类。

**1) 同一编排文件中的内部服务（`deploy/docker-compose.yml`）**

| 服务               | 容器名           | 说明                                                                      |
| ------------------ | ---------------- | ------------------------------------------------------------------------- |
| `openclaw-gateway` | openclaw-gateway | OpenClaw 主网关，承载所有 agent 运行时                                    |
| `coder-copilot`    | coder-copilot    | GitHub Copilot ACP Harness，通过 SSH 向 gateway 暴露 `copilot` 编码 agent |

**2) 编排外的外部服务（但被 OpenClaw 依赖）**

| 服务                                  | 所在位置                              | 作用                                      |
| ------------------------------------- | ------------------------------------- | ----------------------------------------- |
| `litellm-gateway`                     | 外部 Compose 网络 `local-llm-service` | 提供统一模型推理入口（OpenAI 兼容接口）   |
| 宿主机 Chrome CDP (`172.17.0.1:9222`) | 部署主机                              | 提供 browser 插件可复用的宿主机浏览器会话 |
| GitHub / 飞书等公网端点               | 公网                                  | Git 拉取、Copilot 鉴权、飞书收发消息等    |

### 网络拓扑

- `openclaw-gateway` 同时加入三个网络：
  - `openclaw-internal`：与 `coder-copilot` 通信（内部隔离网段）。
  - `local-llm-service`：访问编排外的 `litellm-gateway`。
  - 宿主机默认容器网络（bridge）：用于访问公网端点，并作为到 `172.17.0.1:9222` 的宿主机侧可达路径。
- `coder-copilot` 加入 `openclaw-internal`，为 gateway 提供服务。

网络拓扑如下图所示：

```text
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
openclaw-gateway  ----------HTTPS/WebSocket outbound-----------> GitHub / Feishu / Others
```

#### OpenClaw 访问这些服务的方式

- 访问 `coder-copilot`：
  - 在 gateway 容器内通过 `coder_acp_cmd.sh` 执行 `ssh coder-copilot ...`。
  - `~/.ssh/config` 中启用 SSH 连接复用（`ControlMaster/ControlPath/ControlPersist`），降低 ACP 多次调用开销。
- 访问模型服务 `litellm-gateway`：
  - `openclaw_conf.json` 中 provider `litellm.baseUrl=http://litellm-gateway:8081/v1`。
  - 因为 gateway 连接在 `local-llm-service` 网络上，可直接通过服务名解析访问。
- 访问宿主机 Chrome CDP：
  - `start-gateway.sh` 启动时建立 SSH 隧道账号 `cdp_tunnel`，将容器内 `127.0.0.1:9222` 转发到宿主机 `172.17.0.1:9222`。
  - browser 插件随后通过本地 `9222` 访问到宿主机 Chrome 调试端口。
- 访问公网服务（飞书 / GitHub 等）：
  - 通过容器默认出口网络直连公网。
  - 凭据由 `deploy/.env` 注入（如飞书 app 凭据、Copilot token、模型 key）。

#### SSH 密钥

部署脚本为 gateway 容器生成密钥对 auth，并将其配置为访问 github.com、cdp_tunnel 和 coder-copilot 的公共密钥。

### 环境变量

部署脚本会在部署服务器的部署目录下创建一个 `.env` 文件，包含容器编排中引用的所有环境变量（例如飞书 app secret、litellm api key 等）。你知道这个文件的存在即可，不要试图去读取它。

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
2. 从 `package.json` 读取版本号，拼装镜像 tag（`krepus.com/openclaw:<version>-build<timestamp>`）。
3. 构建 OpenClaw 主镜像（传递 `OPENCLAW_DOCKER_JS_PACKAGES`、`OPENCLAW_INSTALL_BROWSER=1` 等 build-arg）。
4. 构建 `coder-copilot` Harness 镜像（`krepus.com/coder-copilot:<copilot_version>`）。
5. 导出两个镜像为 `.tar.gz`，通过 SSH 传输到目标主机并导入。
6. 将配置文件、容器中用到的脚本以及选装的插件打包传输到部署目录。
7. 在目标主机初始化运行目录，并生成环境变量文件。
8. 执行 `docker compose up -d` 拉起服务。

### OpenClaw 插件安装

插件分为 `预装` 和 `选装` 两类：

- 预装插件连同其依赖库将直接打包进 OpenClaw 镜像，详见 `Dockerfile`。
- 选装插件列表在部署脚本 `deploy_openclaw.sh` 中定义，打包传输到部署目录并挂载在 openclaw-gateway 容器上，由 `start-gateway.sh` 在 Gateway 启动时自动检测并安装。

---
