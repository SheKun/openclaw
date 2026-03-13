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
