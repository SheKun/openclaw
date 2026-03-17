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
