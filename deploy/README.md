# OpenClaw 定制部署说明

> **OpenClaw版本**：`v2026.4.15`
>
> 本文档记录了将 OpenClaw 以容器方式部署到服务器的部署文件、OpenClaw配置文件、部署方法以及对少数源码进行的补丁。

---

## 部署文件

```
deploy/
├── README.md                   # 本文档
├── .env                        # 本地环境变量，包含所有密钥（不入库，见下方变量说明）
├── docker-compose.yml          # 定制化 Compose 编排文件
├── openclaw_conf.json          # OpenClaw 主配置（agents、channels、models、plugins）
├── start-gateway.sh            # Gateway 容器启动包装脚本
├── deploy_openclaw.sh          # 本地构建 + SSH 远程部署脚本
├── create_ssh_user.sh          # SSH 用户初始化工具（被 coder-copilot 容器调用）
├── coding_harness/
│   └── copilot/                # GitHub Copilot ACP Harness 镜像定义
│       ├── Dockerfile
│       ├── coder_entry.sh      # Harness 容器入口脚本
│       ├── coder_acp_cmd.sh    # ACP 命令包装（挂载到 gateway 容器）
│       ├── sshd_config         # 安全加固的 SSH 服务配置
│       └── copilot-instructions.md
└── myextensions/
    └── guidance/               # 自定义全局规则注入插件
        ├── index.ts
        ├── index.test.ts
        ├── openclaw.plugin.json
        └── package.json
```

---

## 服务器配置

- 操作系统：ubuntu 桌面版
- 必备软件：

1. chrome : 提供浏览器CDP服务
2. podman & podman-compose ： 运行容器

---

## 一、部署架构

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

#### 网络连接关系

- `openclaw-gateway` 同时加入三个网络：
  - `openclaw-internal`：与 `coder-copilot` 通信（内部隔离网段）。
  - `local-llm-service`：访问编排外的 `litellm-gateway`。
  - 宿主机默认容器网络（bridge）：用于访问公网端点，并作为到 `172.17.0.1:9222` 的宿主机侧可达路径。
- `coder-copilot` 加入 `openclaw-internal` ， 为gateway提供服务。

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
- 访问公网服务（飞书/GitHub 等）：
  - 通过容器默认出口网络直连公网。
  - 凭据由 `deploy/.env` 注入（如飞书 app 凭据、Copilot token、模型 key）。

#### SSH密钥

部署脚本为 gateway 容器生成密钥对auth，并将其配置为访问github.com、cdp_tunnel和coder-copilot的公共密钥

### Agent 架构

配置了三个 agent：

- **steward**（名称 Adam，默认 agent）：主助手，接入飞书 `steward` 账号，使用 `qwen3.6-plus` 模型，具备完整工具集和丰富技能。
- **coder**（名称 Ape）：编码 agent，运行时为 ACP 模式，底层调用 `coder-copilot` 容器中的 GitHub Copilot CLI，接入飞书 `coder` 账号（限指定用户 DM）。
- **planner**（名称 Fox）：规划 agent，使用 `qwen3.6-flash` 轻量模型，接入飞书 `planner` 账号，工具集受限（无子 agent）。

### 模型提供者

所有模型通过内网 LiteLLM 网关统一代理（`http://litellm-gateway:8081/v1`）：

| 模型 ID         | 名称          | 特性                             |
| --------------- | ------------- | -------------------------------- |
| `qwen3-max`     | Qwen3 Max     | 推理模型，纯文本，上下文 262K    |
| `qwen3.6-plus`  | Qwen3.6 Plus  | 推理模型，文本+图像，上下文 1M   |
| `qwen3.6-flash` | Qwen3.6 Flash | 推理模型，文本+图像，上下文 1M   |
| `kimi-k2.5`     | Kimi K2.5     | 推理模型，文本+图像，上下文 262K |

`perplexity` 插件的 `webSearch` 接口也通过 LiteLLM 代理，模型为 `qwen3.6-flash-search`，实现以国内 Qwen 搜索模型伪装 `web_search` 工具。

---

## 二、配置说明

### 2.1 主配置文件（`openclaw_conf.json`）

完整的 OpenClaw 配置，关键定制点如下：

**Gateway**

- `bind: lan`，端口 `18789`，TLS 自动生成，认证模式 `token`。

**记忆后端**

- `memory.backend: qmd`（结构化记忆）。

**启用的插件**

- `browser`、`feishu`、`lobster`、`open-prose`、`llm-task`、`guidance`、`acpx`

插件特殊配置：

- `llm-task`：限制为 `litellm/qwen3.6-flash`，默认 provider 为 `litellm`。
- `acpx`：注册 `copilot` agent，命令为 `/usr/local/bin/coder_acp_cmd.sh`（挂载自 `coding_harness/copilot/`）。
- `perplexity`：`webSearch` 指向 LiteLLM，模型 `qwen3.6-flash-search`。
- `guidance`：注入四个 markdown 文件（`workspace-shared/AGENTS.md`、`TOOLS.md`、`SOUL.md`、`USER.md`）。

**消息队列**

- `collect` 模式，防抖 1000ms，上限 20 条，超限时 `summarize`。

**飞书频道**

- DM 策略和群组策略均为 `allowlist`，通过 `allowFrom` 和 `groupAllowFrom` 限定授权用户/群组。
- 三个飞书账号（`steward`/`coder`/`planner`）的凭据通过环境变量注入。

### 2.2 环境变量（`../.env`（全局）和 `deploy/.env`（本地））

`.env` 文件包含所有密钥，例如，feishu app secret、litellm api key等，被部署脚本访问，当不入库也不能被编码agent访问。

---

## 三、部署流程

### 3.1 一键构建 + 远程部署

```bash
# 默认部署到 rmbook 主机
bash deploy/deploy_openclaw.sh

# 指定目标主机
bash deploy/deploy_openclaw.sh my-server
```

脚本逻辑：

1. 加载 `../.env`（全局）和 `deploy/.env`（本地）环境变量。
2. 从 `package.json` 读取版本号，拼装镜像 tag（`krepus.com/openclaw:<version>-build<timestamp>`）。
3. 构建 OpenClaw 主镜像（传递 `OPENCLAW_DOCKER_JS_PACKAGES`、`OPENCLAW_INSTALL_BROWSER=1` 等 build-arg）。
4. 构建 `coder-copilot` Harness 镜像（`krepus.com/coder-copilot:<copilot_version>`）。
5. 导出两个镜像为 `.tar.gz`，通过 SSH 传输到目标主机并导入。
6. 在目标主机上生成环境变量文件，`docker compose up -d` 拉起服务。

### 3.2 Gateway 启动脚本（`start-gateway.sh`）

容器启动时由 Compose `command` 调用，主要步骤：

1. **APT 缓存配置**：移除 `docker-clean` 钩子，持久化 `.deb` 包缓存（利用 Docker volume `apt_archives`）。
2. **清理遗留 Browser 锁文件**：`rm -rf ~/.openclaw/browser/openclaw`，防止 browser 工具因异常退出无法重启。
3. **建立 CDP 隧道**：通过 SSH 将宿主机 `9222` 端口转发到容器内，实现 agent 使用宿主机 Chrome 进行浏览器自动化。SSH host alias 为 `cdp_tunnel`，配置见 `~/.ssh/config`。
4. **自动安装 extensions**：扫描 `/home/node/.openclaw/extensions/`，对每个目录执行 `plugins install` 和 `plugins enable`（即 `myextensions/` 下的自定义插件）。
5. **同步工作空间**：对 `~/.openclaw/workspace-*` 下所有 git 仓库执行 `git pull`。
6. **启动 Gateway**：`node openclaw.mjs gateway --allow-unconfigured`，等待端口就绪后进入 `wait` 守护。

---

## 四、GitHub Copilot ACP Harness

位于 `deploy/coding_harness/copilot/`，为 `coder` agent 提供 ACP 编码能力。

### 工作原理

1. `coder-copilot` 容器运行 OpenSSH Server，安装了 `@github/copilot` CLI。
2. `coder_entry.sh` 在容器启动时初始化 sshd，并调用 `create_ssh_user.sh` 配置 `root` 用户的 SSH 公钥（来自 `OPENCLAW_PUB_KEY` 环境变量）。
3. `coder_acp_cmd.sh` 被挂载到 gateway 容器的 `/usr/local/bin/`，gateway 通过该脚本以 SSH 方式调用 `copilot --acp --stdio --allow-all-tools --allow-all-paths --allow-all-urls`。
4. `acpx` 插件中 `copilot` agent 的 `command` 字段指向此脚本，完成 ACP 会话桥接。

### SSH 安全配置（`sshd_config`）

- 禁用密码认证，仅允许公钥认证。
- 禁用 X11 转发、TCP 转发、Agent 转发、隧道。
- 限制加密算法为现代安全套件（Ed25519、ChaCha20、AES-GCM、HMAC-SHA2-etm）。
- 超时：ClientAliveInterval 300s，MaxAuthTries 3，LoginGraceTime 30s。

---

## 五、自定义插件（guidance）

位于 `deploy/myextensions/guidance/`，是一个 `kind: context-engine` 类型的插件，实现全局规则注入。

### 功能

- 从 `plugins.entries.guidance.config.files` 配置的文件列表中读取 Markdown 内容。
- 通过 `registerContextEngine` 将内容注入每次对话的 system prompt addition。
- 当前注入的文件：`workspace-shared/AGENTS.md`、`TOOLS.md`、`SOUL.md`、`USER.md`（相对于 `~/.openclaw`）。
- 通过 `plugins.slots.contextEngine: "public-guidance"` 激活为默认上下文引擎。

### 安装方式

由 `start-gateway.sh` 在 Gateway 启动时自动检测并安装，无需手动操作。

---

## 六、源码补丁

以下是相对于 `v2026.4.15` 基线对上游源码做出的**功能性**修改。跟进上游版本时需确认这些变更是否已被合并，或需要重新应用。

### 6.1 `Dockerfile` — 构建阶段调整

**涉及文件**：`Dockerfile`

**变更内容**：

- 将 `OPENCLAW_DOCKER_APT_PACKAGES` 安装步骤移到构建的最后阶段，使得后续在镜像中新增小工具时避免执行不必要的构建步骤
- 新增 `OPENCLAW_DOCKER_JS_PACKAGES` build-arg，在主镜像中支持通过 `npm install -g` 预装全局 JS 工具（如 skill 依赖的 CLI 工具）。
- 浏览器安装后自动将 Chromium 可执行路径写入 `/app/.env`：`CHROMIUM_EXECUTABLE_PATH=<path>`，供 browser 插件直接读取。

### 6.2 `extensions/browser` — 导航超时可配置化

**涉及文件**：

- `extensions/browser/src/browser-tool.ts`：browser 工具对外暴露的 CLI/ACP 接口定义
- `extensions/browser/src/browser/client-actions-core.ts`：browser server HTTP 客户端，封装导航等操作请求
- `extensions/browser/src/browser/routes/agent.snapshot.ts`：browser server 端路由，处理导航+快照请求
- `extensions/browser/src/browser/cdp.test.ts`：CDP 连接单元测试
- `extensions/browser/src/browser/routes/agent.snapshot.test.ts`：agent snapshot 路由单元测试

**动机**：解决 agent 连续调用 browser 工具时，打开较大页面超时导致的竞争问题（参见提交 `08bc3770a0`、`d5bf4144c1`）。

**变更内容**：

- `browser-tool.ts`：`navigate` 命令新增 `timeoutMs` 参数（默认 25000ms），并通过 proxy 请求体传递给 browser server。
- `client-actions-core.ts`：`browserNavigate` 函数新增 `timeoutMs` 可选参数；fetch 超时设为 `requestedTimeout + 5000ms`（留出缓冲）。
- `routes/agent.snapshot.ts`：从请求体中解析 `timeoutMs`，透传给 CDP 导航调用。
- `cdp.test.ts`：所有 `createTargetViaCdp` 调用补充 `ssrfPolicy: { allowPrivateNetwork: true }`，使测试能连接 localhost CDP 端点。
- `agent.snapshot.test.ts`：在 `listTabs` mock 的首次返回中补充第二个 tab，匹配 `resolveTargetIdAfterNavigate` 更新后的行为。

### 6.3 仓库工作区配置

**涉及文件**：

- `.vscode/settings.json`：VSCode 工作区设置
- `.gitignore`：Git 忽略规则
- `.dockerignore`：Docker 构建上下文忽略规则
- `.github/labeler.yml`：PR 自动标签规则

**变更内容**：

- `.vscode/settings.json`：将 `formatOnSave` 改为 `false`，防止编辑器自动格式化引入无意义 diff，干扰与上游的对比。
- `.gitignore`：添加 `openclaw.code-workspace`，避免本地 VSCode 工作区文件被误提交。
- `.dockerignore`：补充排除一批构建无关文件，包括 IDE 配置（`.vscode/`、`.github/`）、部署脚本（`deploy/`、`fly.toml`、`docker-compose.yml` 等）和文档（`ARCHITECTURE.md`），减小构建上下文体积。
- `.github/labeler.yml`：添加 `extensions: guidance` 标签规则，使 PR 涉及 `deploy/myextensions/guidance/` 时自动打标签。

---

## 七、跟进上游版本指南

1. 将新版本 tag 合并到本分支：`git fetch upstream && git merge v<new-version>`。
2. 解决冲突后，重点核查以下文件是否需要重新应用补丁：
   - `Dockerfile`（构建阶段顺序、新增 build-arg）
   - `extensions/browser/src/browser-tool.ts`
   - `extensions/browser/src/browser/client-actions-core.ts`
   - `extensions/browser/src/browser/routes/agent.snapshot.ts`
3. 更新本文档顶部的**基线版本**标注。
4. 运行 `pnpm build` 确认编译通过，`pnpm test` 确认测试无回归。
