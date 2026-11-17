# 给 Codex 接入拾刻

1. 在运行 Codex 的同一台 Mac 打开拾刻，在「Agent」页点击「启动服务」，或从拾刻菜单栏开启 MCP。开启后，同一台 Mac 上的应用可通过本机端点只读查询完整记录，照片与字段随同返回；停止服务会关闭访问。
2. 注册拾刻的 MCP 端点。升级前已经配置过拾刻时，用同一条命令更新现有的 `shake` 项，或仅从配置里的 `[mcp_servers.shake]` 删除旧的 `bearer_token_env_var`。

   ```sh
   codex mcp add shake --url http://127.0.0.1:17876/mcp
   ```

   等效配置：

   ```toml
   [mcp_servers.shake]
   url = "http://127.0.0.1:17876/mcp"
   ```

3. 新开 Codex 会话，用 `list_categories` 检查连接，无需先查私人记录。需要安装 Skill 时，在拾刻 Agent 页点击「安装 shake-life-log Skill」，或把本目录放到 `~/.agents/skills/shake-life-log`。

## 从 iPhone 导入记录

让 iPhone 与 Mac 连接同一 Wi-Fi。Mac 拾刻打开「设置 → 局域网同步」并点击「开启接收」，保持页面打开。iPhone 在「我的 → 局域网同步」扫码，核对接收端，再点击「同步到 Mac」。

局域网接收用端口 `17877` 和约 10 分钟有效的配对码，保留手机原记录 ID，跳过 Mac 已有的同 ID 记录。MCP 使用独立的 `127.0.0.1:17876`，仅供同一台 Mac 查看已经入库的记录。

## 排查

| 现象 | 检查 |
| --- | --- |
| 没有 `shake` 工具 | 确认 Codex 在同一台 Mac 上、已配置端点，再开一个新会话。 |
| 无法连接 | 检查拾刻 Agent 页是否显示「运行中」。使用代理时让 `127.0.0.1` 和 `localhost` 直连。 |
| 仍提示 HTTP 401 或缺少环境变量 | 确认运行的是新版 Mac 拾刻，并移除 Codex 的旧令牌环境变量配置，再开新会话。 |
| 文字可查，图片不可见 | 检查照片是否已到 Mac、客户端模型是否支持图像，以及 `photo.content_index` 是否指向结果里的 JPEG 图像块。 |
| iPhone 上有记录，Mac 查不到 | 先在 Mac 时间线核对，再检查导入结果、日期、类别和分页。同 ID 的局域网重传保留 Mac 版本。 |
