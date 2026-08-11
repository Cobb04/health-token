# clawd-on-desk 的 Codex 状态接入溯源

日期：2026-08-11
结论基线：

- `rullerzhou-afk/clawd-on-desk`：[`640a816aa72644293e0ef3d1103b78425ad88eee`](https://github.com/rullerzhou-afk/clawd-on-desk/tree/640a816aa72644293e0ef3d1103b78425ad88eee)
- Health Token：[`43e87c744d6d4ca8a15b294df2db9000b9d6d416`](https://github.com/Cobb04/health-token/tree/43e87c744d6d4ca8a15b294df2db9000b9d6d416)
- 本机 Codex CLI：`codex-cli 0.144.1`
- Codex Desktop 内置 CLI：`codex-cli 0.147.0-alpha.6.5`

范围：只调查 Codex 的 hook 安装、授权、运行时事件、rollout fallback 与连接健康；没有修改生产代码或测试。

## 先说结论

Clawd 并没有私有接口。它采用的是一条公开、可复现的双通路：

1. **实时主通路**：向 `~/.codex/hooks.json` 合并 command hooks，让 Codex 把生命周期 JSON 写到 hook 进程的 `stdin`；hook 再把状态 POST 到 Clawd 的本地 HTTP 服务。
2. **fallback 通路**：每 1.5 秒增量轮询 `~/.codex/sessions/**/rollout-*.jsonl`，补齐 hook 尚未覆盖、被禁用或漏达的状态。

Health Token 已经拥有同样的两条通路，而且 rollout reader 在资源上更克制、事件落盘也更隐私安全。现场验证发现两条通路各有一个独立阻断点：

- **official hook**：Clawd 的六个 handler 已有 Codex trust 记录，Health Token 的 handler 没有；
- **rollout fallback**：当前 Codex Desktop rollout 的第一条 `session_meta` 是 19,078 bytes，而 Health Token 基线只允许读取 8 KiB metadata prefix，导致 session ID 未建立，后续 tool call 无法生成事件。

所以 Clawd 有反应而 Health Token 没有，并不是一个单点故障，也不能只靠改“已连接”文案解决。

因此最小修复不是复制 Clawd 的 HTTP 服务或 rollout monitor，而是补齐四件事：

1. 把 rollout 的 metadata prefix 提高到仍然有界的 32 KiB；
2. 检查 `[features].hooks` 与 hook trust；
3. 把“rollout 可读”和“official hook 已实际到达”拆成两个健康维度；
4. 在需要授权时明确提示：**打开 Terminal 中的 Codex CLI，输入 `/hooks` 审核 Health Token**。`/hooks` 是 CLI 的 TUI 命令，不是 Codex Desktop 的命令。

## 1. Clawd 如何安装 Codex hook

### 1.1 自动同步，而不是等用户手工写 JSON

Clawd 把 Codex 声明为 `hook+log-poll` 集成，并把 hooks 配置格式标成 `codex-hooks-json`；fallback 目录是 `~/.codex/sessions`，间隔为 1500 ms。来源：[agents/codex.js#L1-L53](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex.js#L1-L53)。

本地 HTTP 服务启动后，Clawd 会异步同步所有已启用集成，包括 Codex；这避免 hook 文件 I/O 阻塞应用启动。来源：[src/server.js#L845-L853](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/server.js#L845-L853)、[src/integration-sync.js#L679-L692](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/integration-sync.js#L679-L692)。

安装器定位 `$CODEX_HOME`，否则使用 `~/.codex`，同时取得 `hooks.json` 与 `config.toml`。来源：[hooks/codex-install-utils.js#L20-L49](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-install-utils.js#L20-L49)。

### 1.2 写哪些事件

当前 Clawd 注册六个 official hook：

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `Stop`

普通事件超时 30 秒，`PermissionRequest` 因为要等待用户审批，超时 600 秒。来源：[hooks/codex-install-utils.js#L27-L40](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-install-utils.js#L27-L40)。

安装器以 `codex-hook.js` 为 ownership marker，只更新或删除自己拥有的 handler，保留其他应用的 hook group；新 handler 的形状是 `{type:"command", command, timeout}`，包在独立 matcher group 中。来源：[hooks/codex-install-utils.js#L654-L723](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-install-utils.js#L654-L723)。

Health Token 的 `CodexHookInstaller` 已采用相同的“合并并保留第三方配置”结构，而且多注册了当前官方文档已经支持的 `SubagentStart` / `SubagentStop`。来源：[CodexHookInstaller.swift#L30-L48](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenCore/CodexHookInstaller.swift#L30-L48)、[AgentModels.swift#L3-L12](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenCore/AgentModels.swift#L3-L12)。这一部分没有必要退回去照抄 Clawd 的较窄事件表。

### 1.3 feature flag

Clawd 会处理 `[features].hooks`：

- 已显式为 `false` 时，普通自动同步尊重用户选择，不强行开启；
- 缺失时写入 `hooks = true`；
- 旧的 `codex_hooks` 会迁移到规范的 `hooks`，并保留显式 `false`；
- Doctor 的显式 Repair 才可通过 `force` 覆盖 `false`。

来源：[hooks/codex-install-utils.js#L364-L449](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-install-utils.js#L364-L449)、[src/integration-sync.js#L297-L325](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/integration-sync.js#L297-L325)。

OpenAI 当前官方文档说明 hooks 已默认启用，规范关闭方式仍是 `[features].hooks = false`，`codex_hooks` 只是 deprecated alias。来源：[OpenAI Codex Hooks — Turn hooks off](https://developers.openai.com/codex/hooks#turn-hooks-off)。本机用全新临时 `CODEX_HOME` 验证，两套本机 CLI 的 `codex features list` 都报告 `hooks stable true`。

所以对于当前 Codex，缺少 `hooks = true` 本身通常不再阻断；但 Health Token 要成为独立产品，仍应像 Clawd 一样**识别并尊重显式 false**，而不是只看 `hooks.json` 中有没有自己的 command。

## 2. trust 才是当前机器的真实阻断点

### 2.1 Codex 的规则

OpenAI 官方文档规定：非 managed command hook 在运行前必须由用户审核并信任；信任绑定到 hook definition 的当前 hash，新增或变更都会重新进入待审核。审核入口是 **Codex CLI 的 `/hooks`**。来源：[OpenAI Codex Hooks — Review and trust hooks](https://developers.openai.com/codex/hooks#review-and-trust-hooks)。

本机 CLI 的 `--help` 还提供 `--dangerously-bypass-hook-trust`，明确说明它只适用于外部已经审查过 hook 的一次性自动化。Health Token 不应使用该参数，更不应自行伪造 `[hooks.state]`。

### 2.2 Clawd 如何检查 trust

Codex 把 trust 记录存在 `config.toml` 的 `[hooks.state."<hook-id>"]` 下，Clawd 根据 hook 在 JSON 中的位置构造 ID：

```text
<hooks.json absolute path>:<snake_case event>:<matcher-group index>:<handler index>
```

然后检查该 table 是否带 `trusted_hash = "sha256:..."`。来源：[src/doctor-detectors/codex-features-check.js#L100-L131](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/doctor-detectors/codex-features-check.js#L100-L131)、[src/doctor-detectors/codex-features-check.js#L149-L223](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/doctor-detectors/codex-features-check.js#L149-L223)。

Doctor 将三类状态分开：feature disabled、needs review、not registered / broken path。来源：[src/codex-hook-health.js#L22-L68](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/codex-hook-health.js#L22-L68)。

注意：Clawd 目前只检查 `trusted_hash` 是否存在，并没有自己重算当前 hook hash；而且 trust inspector 只检查当前确实存在的 Clawd positions，基础路径校验是“任一 marker command 可验证”即可，所以静态检查不能独立证明六个事件全部完整。来源：[src/doctor-detectors/agent-integrations.js#L302-L366](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/doctor-detectors/agent-integrations.js#L302-L366)、[src/doctor-detectors/agent-integrations.js#L1367-L1372](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/doctor-detectors/agent-integrations.js#L1367-L1372)。这是一个近似静态诊断；真正可靠的连接验证仍是实际收到 hook 事件。Health Token 现有 `allSatisfy` 完整性检查反而更严格，不应退化。

### 2.3 本机证据：为什么 Clawd 热、Health Token 静

对本机配置做了只读结构检查，结果是：

| event | Clawd 位置 | Health Token 位置 | 本机 trust 记录 |
| --- | --- | --- | --- |
| `SessionStart` | `0:0` | `1:0` | 只有 `0:0` |
| `UserPromptSubmit` | `0:0` | `1:0` | 只有 `0:0` |
| `PreToolUse` | `0:0` | `1:0` | 只有 `0:0` |
| `PermissionRequest` | `0:0` | `1:0` | 只有 `0:0` |
| `PostToolUse` | `0:0` | `1:0` | 只有 `0:0` |
| `Stop` | `0:0` | `1:0` | 只有 `0:0` |
| `SubagentStart` | 无 | `0:0` | 无 |
| `SubagentStop` | 无 | `0:0` | 无 |

这与用户看到的行为完全一致：Clawd 的 command 已被 Codex 信任，可以实时收到事件；Health Token 是新 matcher group，尚未信任，Codex 会跳过它。`hooks.json` 中存在 Health Token command 只证明“已配置”，不能证明“会执行”。

## 3. Clawd 如何消费 official hook

Codex 会把单个 JSON object 写到 hook 的 `stdin`。当前官方公共字段包括 `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`model`；工具相关 hook 还会包含工具名与输入。来源：[OpenAI Codex Hooks — Common input fields](https://developers.openai.com/codex/hooks#common-input-fields)。

Clawd 的 `codex-hook.js` 读取 stdin 后做两类处理：

- 生命周期事件映射：`SessionStart → idle`、`UserPromptSubmit → thinking`、`PreToolUse/PostToolUse → working`、`Stop → turn end`。来源：[hooks/codex-hook.js#L52-L60](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L52-L60)、[hooks/codex-hook.js#L405-L476](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L405-L476)。
- `PermissionRequest`：把请求 POST 到本地服务，最长等待 590 秒，再把经过白名单清洗的 allow / deny decision 写回 stdout；失败时输出 `{}`，让 Codex 原生流程接管。来源：[hooks/codex-hook.js#L293-L335](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L293-L335)、[hooks/codex-hook.js#L479-L496](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L479-L496)、[hooks/codex-hook.js#L622-L646](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L622-L646)。

状态通过 localhost HTTP POST 进入 Electron 主进程，而非写共享事件文件。hook 接收失败时，`SessionStart` 还可以自动启动 Clawd 后重试。来源：[hooks/codex-hook.js#L648-L717](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L648-L717)。

Health Token 没有权限审批需求，因此不应复制这段阻塞式 HTTP/decision 流程。现在的实现更合适：helper 只把 hook 输入归一化为小型 `AgentEvent`，写入本地 inbox，并始终输出 `{}`，绝不替用户回答。来源：[HealthTokenHook.swift#L4-L16](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenHook/HealthTokenHook.swift#L4-L16)、[CodexEventInbox.swift#L32-L68](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenCore/CodexEventInbox.swift#L32-L68)。

## 4. Clawd 的 rollout fallback

Clawd 始终保留 JSONL 监控；官方 hooks 只覆盖实时主路径，rollout 负责 web search、compaction、aborted turn、request_user_input、quota/metadata 以及 hook 被禁用或漏达的会话。映射表见 [agents/codex.js#L19-L50](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex.js#L19-L50)。

监控器启动时先扫描，随后每 1500 ms poll；使用文件 offset 增量读取，并有防历史重放、活跃文件窗口、文件/字节/重试预算。来源：[agents/codex-log-monitor.js#L1-L15](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex-log-monitor.js#L1-L15)、[agents/codex-log-monitor.js#L34-L61](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex-log-monitor.js#L34-L61)、[agents/codex-log-monitor.js#L206-L247](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex-log-monitor.js#L206-L247)。

Clawd 不依赖并不存在于其 official hook 事件表中的 `SubagentStart/Stop` 来识别子 agent。它读取 rollout 第一条 `session_meta`，优先识别 `payload.source.subagent`，再看 `agent_role`、`agent_type`、parent id；角色一旦升级为 subagent 不会被后续 root 信号降级。来源：[hooks/codex-subagent-fields.js#L30-L94](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-subagent-fields.js#L30-L94)、[agents/codex-subagent-classifier.js#L22-L75](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex-subagent-classifier.js#L22-L75)。

当同一 session 最近收到 official hook 时，Clawd 用 10 分钟 TTL 抑制 rollout 中已被 official hook 覆盖的重复事件；如果 official `Stop` 漏失，但 session 仍处于 working-like，允许 JSONL `task_complete` 穿透并收尾。来源：[src/agent-runtime-main.js#L14-L37](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/agent-runtime-main.js#L14-L37)、[src/agent-runtime-main.js#L96-L130](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/agent-runtime-main.js#L96-L130)、[src/codex-official-activity.js#L5-L18](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/codex-official-activity.js#L5-L18)。

Health Token 的 rollout reader 已覆盖 function/custom tool、plan、attention、completion/abort 与 subagent metadata，而且默认预算更小：8 个候选、512 个目录项、64 KiB/文件、256 KiB/poll、32 KiB/record。来源：[CodexRolloutMonitor.swift#L7-L50](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenCore/CodexRolloutMonitor.swift#L7-L50)、[AgentEventAdapter.swift#L109-L220](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenCore/AgentEventAdapter.swift#L109-L220)。没有理由用 Clawd 更大的 reader 替换它。

但基线的 `maxSessionMetadataBytes` 只有 8 KiB，而本机真实 Desktop `session_meta` 为 19,078 bytes。Clawd 对第一条 metadata line 使用独立的 256 KiB 上限，并明确说明必须读到完整换行，不能让截断后的 JSON parse failure 把 session/subagent 身份悄悄丢掉。来源：[agents/codex-log-monitor.js#L67-L88](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex-log-monitor.js#L67-L88)、[hooks/codex-hook.js#L135-L174](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L135-L174)。

最小适配不是照搬 256 KiB，而是把 Health Token 的 metadata prefix 提高到已有 `maxRecordBytes` 的 32 KiB，并保留全部总量预算。18 KiB 回归样本已经证明：旧值无法 anchor session，新值可让后续 Desktop tool call 生成正确 session event，同时不读取或持久化 metadata 内容。

## 5. 两边“连接健康”的关键差异

Clawd 把健康拆成两层：

1. **静态健康**：hook 是否注册、脚本路径是否有效、feature 是否关闭、trust record 是否存在。来源：[src/doctor-detectors/agent-integrations.js#L946-L995](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/doctor-detectors/agent-integrations.js#L946-L995)。
2. **运行时验证**：在测试窗口里，只有本地 HTTP 服务真正 `accepted` hook event 才算 `http-verified`；仅看到 rollout 文件 mtime 变化却没有 hook event，会报 hook 路径未到达。来源：[src/doctor-hook-activity.js#L135-L184](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/src/doctor-hook-activity.js#L135-L184)。

Health Token 当前有两个误判点：

- `CodexHookInstaller.health` 只要“已写入 hooks.json + 最近观察到任何事件”就返回 `.connected`，没有检查 feature 或 trust。来源：[CodexHookInstaller.swift#L80-L101](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenCore/CodexHookInstaller.swift#L80-L101)。
- `CodexObservationActivity` 把 `hookEventCount` 和 `rolloutEventCount` 合并为同一个 `lastObservedAt`；因此纯 rollout 活动也会把 UI 标成“已连接”。来源：[HydrationAppModel.swift#L280-L303](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenApp/HydrationAppModel.swift#L280-L303)。

这正是应该从 Clawd 借鉴的核心：**来源分流和健康诊断，而不是 UI 或权限代理。**

## 6. 建议的最小适配

### P0：解决这台机器

1. 将 `maxSessionMetadataBytes` 从 8 KiB 调至 32 KiB，并保留真实大 metadata 的回归测试；这是 rollout fallback 能看见当前 Desktop tool call 的前置条件。
2. 增加只读 `CodexHookTrustInspector`：解析 `config.toml` 中 `[features].hooks` 和 `[hooks.state]`，按 Health Token 在 `hooks.json` 中的真实 group/handler 位置构造 expected trust IDs。
3. 状态至少区分：
   - `fallbackActive`：rollout 可读，正常饮水增强可工作；
   - `officialHookNeedsReview`：handler 已安装但缺 trust；
   - `officialHookVerified`：本次应用运行中至少收到一次 Health Token official hook event；
   - `hooksDisabledByUser`：显式 `[features].hooks = false`；
   - `unavailable/error`。
4. 当 `needsReview` 时给出准确动作：`在 Terminal 启动 Codex CLI → /hooks → 选择并信任 Health Token`。不要再让用户在 Codex Desktop 输入 `/hooks`。
5. **绝不自行写入 `trusted_hash`**：这个 hash 是 Codex 对用户审核结果的所有权记录。应用伪造它等于绕过安全边界，而且一旦 Codex 的 canonical hash 算法或 hook shape 改变就会脆弱失效。也不调用 trust bypass，不替用户决策。

### P1：独立产品稳定性

1. 像 Clawd 一样持久化“用户希望启用 Codex 观察”的 intent；启动时自动 reconcile 自己的 handler。现在 Health Token 只用“当前 command 是否完整存在”反推开关状态，应用路径变化后会丢失 intent。来源：[HydrationAppModel.swift#L25-L51](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenApp/HydrationAppModel.swift#L25-L51)。
2. 识别 `[features].hooks = false` 并尊重它；只有明确的 Repair 动作才询问用户是否改为 true。当前 Codex 默认 true，普通 enable 不必无条件写 config。
3. 记录 hook 与 rollout 两个独立 freshness 时间；rollout 到达不能证明 official hook 到达。
4. 保留现有 rollout fallback 和 1 秒刷新；无需复制 Clawd 的 localhost HTTP server。

### 不建议复制

- 不复制 Clawd 的 `PermissionRequest` intercept/allow/deny；Health Token 只观察健康窗口，权限仍应归 Codex。
- 不复制 Clawd 对提示内容、tool input、assistant output、cwd、model、transcript path 的采集。
- 不用 Clawd 的 30/600 秒 timeout；Health Token helper 不阻塞决策，现有 1 秒更安全。
- 不把 Clawd 的六事件表覆盖 Health Token 的八事件表；当前 OpenAI 文档已经列出 `SubagentStart` / `SubagentStop`。

## 7. 隐私与许可证边界

Clawd 为桌宠、跳转、审批与 session dashboard 读取和传递的信息远多于 Health Token：

- `PermissionRequest` 会携带清洗后的 `tool_input`、description、cwd、turn id、transcript path 与 model。来源：[hooks/codex-hook.js#L337-L402](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L337-L402)。
- `Stop` 会从 transcript 读取最后一段 assistant output；普通状态也会读取 session title 和 session metadata。来源：[hooks/codex-hook.js#L435-L457](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/hooks/codex-hook.js#L435-L457)。
- rollout monitor 会解析 assistant text、title、context usage 与 quota。来源：[agents/codex-log-monitor.js#L1650-L1705](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/agents/codex-log-monitor.js#L1650-L1705)。

Health Token 的持久化 `AgentEvent` 只有 kind、session/parent ID、时间、角色、attention 与工具分类，不含提示词、代码、tool 参数或输出。来源：[AgentModels.swift#L30-L66](https://github.com/Cobb04/health-token/blob/43e87c744d6d4ca8a15b294df2db9000b9d6d416/Sources/HealthTokenCore/AgentModels.swift#L30-L66)。这条隐私边界应保留。

另外，clawd-on-desk 当前是 **AGPL-3.0-only**，不是 MIT。来源：[clawd-on-desk LICENSE](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/LICENSE#L1-L18)、[package.json#L71](https://github.com/rullerzhou-afk/clawd-on-desk/blob/640a816aa72644293e0ef3d1103b78425ad88eee/package.json#L71)。因此建议借鉴协议与架构，并依据 OpenAI 官方 hook 契约独立实现；不要逐段复制 Clawd 源码，除非项目明确接受 AGPL 的发布义务。此处只是工程风险提示，不是法律意见。

## 8. 相关提交历史

以下 SHA 来自 upstream git history：

| SHA | 日期 | 意义 |
| --- | --- | --- |
| [`bdf17d2d`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/bdf17d2d843a994f197f6995171210c3a11574d8) | 2026-03-25 | 最早的 Codex rollout adapter / 多 agent 架构 |
| [`8b065127`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/8b06512769c0d8cc2aa11c1fe28afccdba20d760) | 2026-04-26 | 加入 Codex official state hooks 与安装器 |
| [`3d5e1f00`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/3d5e1f0013bcb8e730cd12e9a6df7b14dea4a5eb) | 2026-04-26 | 加入 official `PermissionRequest` 审批通路 |
| [`eba0fa58`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/eba0fa58bdbcf2a59b962827a725b6089859ca5d) | 2026-05-08 | 规范化 `[features].hooks`、legacy 迁移与 trust 诊断 |
| [`4941ecc3`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/4941ecc350733957e989b9c3dabefef4dd57d51e) | 2026-06-04 | 加入 official `Stop` 漏失时的 JSONL completion rescue |
| [`982819b7`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/982819b7165257302e4dbbbc80b47e845ee1bfb7) | 2026-06-30 | 删除 JSONL 审批猜测，审批只信 official hook |
| [`1b375628`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/1b37562809a99ceb35316da67bd044a3c5903637) | 2026-06-30 | 加入 official hook 健康状态与启动提醒 |
| [`1de67cfb`](https://github.com/rullerzhou-afk/clawd-on-desk/commit/1de67cfbcaed118fec8a44134b9d4622595e61e1) | 2026-08-11 | Doctor 明确识别未审核 hooks |

## 最终判断

可以借鉴 Clawd，但不应“把它整套 copy 进来”。Health Token 当前缺的不是状态抓取能力，而是**把 Codex 的配置、trust、official event 与 rollout fallback 分开建模**。

这次本机证据已经把问题拆成两个很小、可独立验证的修复：

1. fallback 侧，19,078-byte `session_meta` 超过旧 8 KiB prefix；提高到有界 32 KiB 后，Desktop tool call 可以被识别；
2. official 侧，Clawd 的 `0:0` handlers 有 trust，Health Token 的 `1:0` handlers 没有；必须由用户在 Codex CLI 审核，应用不能替用户写 `trusted_hash`。

完成 metadata cap、trust inspector、CLI-only 审核指引和 source-specific health，就能解释并修复“Clawd 已经火热感知，但 Health Token 说未连接”的现象，同时保留 Health Token 更小、更私密的实现。
