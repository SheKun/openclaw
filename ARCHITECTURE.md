# OpenClaw Architecture

## 1. 部署与环境 (Deployment and Environment)

- 网关 (Gateway) 以 Docker 容器（`openclaw-gateway`）形式运行。通过 `docker-compose.yml` 可以指定其网络、端口及存储挂载。
- 配置体系结构：通过宿主机目录映射 `openclaw_conf.json` 至容器内的对应路径提供各种设定（网关模式、agents 声明、通讯通道 channels，及模型服务 providers 等）。
  - **动态热加载 (Hot Reload)：** 网关会通过 `chokidar` 监听该配置文件的变化。当修改 `openclaw_conf.json` 时（如 `channels` 配置变化），网关会生成重载计划 (Reload Plan)，支持针对特定通道的动态热重启，而无需重启整个网关服务。
- 绝密配置挂载：通过 `secret_file.json` 提供静态凭据，安全措施之一是在 `start-gateway.sh` 将 Gateway 进程挂起在后台后，立即对 `/tmp/secret_file.json` 执行 `umount`，降低敏感信息的持久暴露。

## 2. 通道集成 (Channels Integration)

### 飞书 (Feishu)

- 飞书通道处于 websocket 连接模式，通过 `channels.feishu.accounts` 定义多个应用账号，当前包括：
  - steward (FEISHU_APP_ID_STEWARD, FEISHU_APP_SECRET_STEWARD)
  - coder (FEISHU_APP_ID_CODER, FEISHU_APP_SECRET_CODER)
  - crawler (FEISHU_APP_ID_CRAWLER, FEISHU_APP_SECRET_CRAWLER)
- **安全实践：** 为增强安全性，上述环境变量仅需要在 Node 网关读取时暂时驻留，当进程后台拉起后，应立刻在包装脚本（如 `start-gateway.sh`）内通过 `unset` 移除相关进程环境变量的副本。

## 3. 扩展与插件机制 (Extensions vs Plugins)

OpenClaw 采用分层的方式管理功能增强，主要区分为构建时的“依赖打包”与运行时的“加载激活”：

- **OPENCLAW_EXTENSIONS (构建参数)：**
  - **对象：** monorepo 内 `extensions/` 目录下的本地扩展。
  - **作用：** 决定哪些扩展的 `package.json` 会参与 Docker 构建阶段的 `pnpm install`。这对于包含二进制依赖或大型底层库（如 Feishu 通道的 SDK）的扩展至关重要。
  - **最佳实践：** 只有通过该参数打包进镜像的扩展，其依赖才是完整的。

- **插件加载与激活 (Loading & Activation)：**
  - **通道类扩展 (Channel Extensions)：** 如 Feishu 插件。只要镜像中已包含其代码（通过上述参数），且在 `channels` 配置中启用了对应通道，系统会自动激活插件，无需额外安装指令。
  - **第三方/远程插件：** 使用 `openclaw plugins install <npm-package>`。该命令会将插件信息写入 `openclaw_conf.json` 并设为 `enabled: true`。

## 4. 模型配置参考 (Model Configuration Reference)

### 4.1 全局注册 (`models`)

定义模型服务商 (Providers) 及其具体模型实例。支持 `mode: "merge"` (默认) 或 `"replace"`。

| 字段      | 类型     | 说明                                                    |
| :-------- | :------- | :------------------------------------------------------ |
| `baseUrl` | `string` | API 基础地址 (必填)                                     |
| `apiKey`  | `Secret` | 模型认证私钥，支持环境变量引用                          |
| `auth`    | `enum`   | 认证方式：`api-key`, `aws-sdk`, `oauth`, `token`        |
| `api`     | `string` | API 协议，如 `openai-completions`, `anthropic-messages` |
| `models`  | `Array`  | 具体模型定义列表                                        |

#### 模型定义字段 (`models[]`)

| 字段            | 说明                                                   |
| :-------------- | :----------------------------------------------------- |
| `id`            | 模型唯一标识符                                         |
| `name`          | 显示名称                                               |
| `contextWindow` | 最大上下文窗口 (tokens)                                |
| `maxTokens`     | 单次输出上限 (tokens)                                  |
| `cost`          | 包含 `input`, `output`, `cacheRead`, `cacheWrite` 成本 |
| `compat`        | 兼容性标志集，如 `supportsTools`, `thinkingFormat`     |

### 4.2 Agent 级配置与参数覆盖

模型可在 Agent 级通过 `model` 和 `params` 进行更细粒度的控制。

#### 模型选择 (`model`)

- **单一格式**: `"provider/model_id"`
- **备用格式**: `{ "primary": "...", "fallbacks": ["..."] }`

#### 调用参数覆盖 (`params`)

支持在 `agents.list[]` 或 `agents.defaults` 中设置，覆盖优先级：Agent 专属 > 全局默认。

| 参数                | 适用范围   | 说明                                 |
| :------------------ | :--------- | :----------------------------------- |
| `temperature`       | 通用       | 生成随机性 (0-2)                     |
| `maxTokens`         | 通用       | 生成 token 上限                      |
| `parallelToolCalls` | OpenAI 系  | 是否允许并行工具调用 (boolean)       |
| `transport`         | 通用       | 传输协议：`sse`, `websocket`, `auto` |
| `cacheRetention`    | Anthropic  | 缓存持久度：`none`, `short`, `long`  |
| `tool_stream`       | Z.AI       | 开启工具调用实时流 (boolean)         |
| `provider`          | OpenRouter | 路由偏好对象，如 `allow_fallbacks`   |

### 4.3 通道定向模型 (`modelByChannel`)

在 `channels` 段定义，允许根据消息来源通道（如 `feishu/steward`）强制指定使用的模型。

## 5. System Prompt 与工作空间上下文 (System Prompt & Workspace Context)

### 5.1 启动引导文件 (Bootstrap Files)

- 系统会自动加载工作空间中的特定文件：`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, `MEMORY.md`。
- 这些文件被统称为 "Bootstrap Files"。

### 5.2 截断与保护 (Truncation & Guards)

- **安全读取**: 所有文件通过边界检查（Boundary Check）读取，确保不超出工作空间根目录。
- **自动截断**: 单文件限制 20k 字符，总预算 150k 字符。采用 "Head-Tail" 模式保留开头和结尾，中间截断。

### 5.3 技能注入 (Skills Injection)

- 动态加载 `workspace/skills`, `workspace/.agents/skills` 等目录下的插件技能。
- 技能文件 (`SKILL.md`) 会被注入到 `## Skills` 章节。

### 5.4 最终组装

- 所有项目上下文文件注入到 `# Project Context` 章节。
- 支持 `SOUL.md` 自动引导 Persona 实现。

## 6. Web Search Providers 深入实现 (Web Search Providers Implementation)

OpenClaw 的内置联网搜索能力 (`web_search` tool) 针对多种底层提供商，在内部实现了不同的衔接机制：

### 6.1 Kimi (基于多轮对话与内置 Function Calling)

- **机制**：完全依靠兼容 OpenAI 的 `/chat/completions` 对话端点。
- **触发**：通过向模型注入非标准的预置工具声明 `{"type": "builtin_function", "function": {"name": "$web_search"}}` 触发搜索。
- **处理**：系统拦截返回的 `tool_calls`。提取 Kimi 响应（`search_results` 或是其 `arguments` JSON）中的引用链接，之后把搜索结果转为 `role: "tool"` 发给模型以完成答案生成（支持最多 3 轮循环对话）。

### 6.2 Gemini (基于 Google 原生 Grounding 功能)

- **机制**：直接使用 Google 原生端点 (`generativelanguage.googleapis.com/...:generateContent`)。
- **触发**：在请求 payload 的 `tools` 中启用原生特性 `[{ "google_search": {} }]`。
- **处理**：一次性生成包含正文的总结，并从 `groundingMetadata.groundingChunks` 提取引用的 URL 数组。内部还实现了最高承载 10 并发的 URL 解析器，用于消除 Google 结果中的中转重定向链以还原真实目标。

### 6.3 Perplexity (双轨制：原生 Search API 与 Chat 接口)

- **原生模式 (Search API)**：默认优先调用官方 API `api.perplexity.ai/search` 端点。支持 `search_domain_filter` 等精准参数。返回由标题、URL、内容 Snippet 组成的搜索结果块集合，并非总结后文字。这将被喂给 OpenClaw 的本地运行大模型阅读。
- **兼容模式 (Chat Completions)**：配合代理端点 (如 OpenRouter) 或特定覆写时，退化走兼容的 `/chat/completions` 接口（甚至把独有过滤参数塞到根节点）。直接获得总结后的最终文字回复，并尝试从非完全标准的响应 JSON 顶层直接抽取额外附带的 `citations` 数组。

## 7. 工作空间上下文注入链路 (Workspace Context Injection Chain)

OpenClaw 为 Agent 注入工作空间 `.md` 文件的完整调用链路如下：

### 7.1 第一阶段：业务逻辑触发

系统在启动 Agent 会话或需要更新上下文时，会调用高层解析函数。

- **解析入口 (`resolveBootstrapContextForRun`)**
  - **文件**: `src/agents/bootstrap-files.ts`
  - **作用**: 协调加载、过滤并构建最终注入 LLM 的上下文文件对象。

- **文件列表解析 (`resolveBootstrapFilesForRun`)**
  - **文件**: `src/agents/bootstrap-files.ts`
  - **作用**: 调用底层加载器获取原始文件列表，并进行初步过滤。

### 7.2 第二阶段：文件系统加载

这一阶段负责从磁盘扫描并读取识别到的引导文件（如 `USER.md`, `TOOLS.md`）。

- **工作空间扫描 (`loadWorkspaceBootstrapFiles`)**
  - **文件**: `src/agents/workspace.ts`
  - **作用**: 定义要加载的文件列表（entries），并循环调用受限的读取函数。

- **安全受限读取 (`readWorkspaceFileWithGuards`)**
  - **文件**: `src/agents/workspace.ts`
  - **作用**: 调用基础设施层的边界安全读取函数，并对读取成功的文件内容进行缓存。

### 7.3 第三阶段：安全边界校验

这是最关键的一环，用于确保文件操作不超出工作空间目录。

- **边界安全打开 (`openBoundaryFile`)**
  - **文件**: `src/infra/boundary-file-read.ts`
  - **作用**: 初始化路径解析，准备进行边界检查。

- **路径解析与越权校验 (`resolveBoundaryPath`)**
  - **文件**: `src/infra/boundary-path.ts`
  - **作用**: 使用 `realpath` 获取规范路径，校验目标文件是否位于指定的 Root 目录下。

### 7.4 第四阶段：物理文件打开与标识校验

在获得 OS 层面打开文件的句柄前后的最终校验。

- **受控文件打开 (`openVerifiedFileSync`)**
  - **文件**: `src/infra/safe-open-sync.ts`
  - **作用**: 核心校验点。使用 `O_NOFOLLOW` 打开文件，并检查 `nlink`（防止硬链接攻击）。此处即为 `nlink > 1` 拦截发生地。

- **文件标识比对 (`sameFileIdentity`)**
  - **文件**: `src/infra/file-identity.ts`
  - **作用**: 比较 `lstat`（路径）和 `fstat`（文件描述符）获取的 `dev` 和 `ino` 是否一致，确保文件在校验和打开之间没有被替换。

### 7.5 第五阶段：注入上下文

- **构建上下文对象 (`buildBootstrapContextFiles`)**
  - **文件**: `src/agents/pi-embedded-helpers.ts`
  - **作用**: 将读取到的 `WorkspaceBootstrapFile` 转换为 `EmbeddedContextFile` 格式，准备作为 System Prompt 的一部分发送给 LLM。
