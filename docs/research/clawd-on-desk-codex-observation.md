# clawd-on-desk 的 Codex 监听实现：clean-room 溯源

日期：2026-08-12

固定基线：

- `rullerzhou-afk/clawd-on-desk`：[`f0745407727dedf9f701e9e01bb9ac64b6e378bc`](https://github.com/rullerzhou-afk/clawd-on-desk/tree/f0745407727dedf9f701e9e01bb9ac64b6e378bc)
- Health Token：[`db6c34b922edd86670de0d145246ae99fd14441d`](https://github.com/Cobb04/health-token/tree/db6c34b922edd86670de0d145246ae99fd14441d)
- OpenAI Hooks 文档：[`Hooks`](https://developers.openai.com/codex/hooks)（2026-08-12 读取）

范围：追踪数据源、轮询、会话发现、metadata 限制、hook/fallback 分工、恢复、去重、健康状态与本地接口；只更新研究笔记，不复制或修改产品代码。

## 结论

Clawd 的成功不是一个隐藏 hook，而是一个经过多轮加固的双通路：

1. official hooks 负责实时生命周期与权限；
2. `~/.codex/sessions/**/rollout-*.jsonl` 轮询负责状态补齐、恢复及 hooks 漏达时的兜底；
3. 两条通路以 session/turn 为键去重，并保留 JSONL completion rescue；
4. 健康状态把“静态配置正确”“hook 真的到达”“只有 rollout 在变化”分开。

最关键的现场差异更具体：**Clawd 在打开 rollout 时先从文件名取得 session UUID，不依赖第一条 metadata 才建立会话**；Health Token 目前必须在 32 KiB 内解析第一条 `session_meta.payload.id`。本机当前真实 Codex Desktop/Subagent metadata 是 **44,217 bytes**，因此 Health Token 得不到 session ID，随后新增的 tool/plan/attention 记录都被忽略；Clawd 的文件名锚点和更宽的读取窗口让它继续工作。

所以本轮应该真正借鉴的是：

- 文件名先锚定 session，metadata 只负责角色/父子关系和一致性校验；
- 完整行、增量 offset、历史回放和跨源去重各自有独立边界；
- rollout 可用不等于 official hook 已验证，空闲也不等于“需要连接”。

## 1. 总体架构

Clawd 自己把 Codex 声明为 `hook+log-poll`：hooks 是生命周期主通路，JSONL 是 fallback；轮询目标是 `~/.codex/sessions` 下的 `rollout-*.jsonl`，周期 1,500 ms。[`agents/codex.js#L1-L54`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex.js#L1-L54)

README 也明确将 Codex 集成描述为 “official hooks with JSONL fallback”，不是单一 hook 或 Clawd 私有协议。[`README.md#L38-L46`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/README.md#L38-L46)

### 数据流

```text
Codex
├── official command hooks
│   └── codex-hook.js ──POST──> 127.0.0.1:<23333...23337>/state|permission
└── ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
    └── CodexLogMonitor (1.5 s 增量轮询)
        └── session state runtime

两路进入 runtime 前后：session + turn fence / official-activity TTL 去重
```

## 2. official hooks：安装、事件和职责

### 2.1 注册哪些 hook

Clawd 当前注册六个事件：

| Codex hook | Clawd 状态 | 用途 |
| --- | --- | --- |
| `SessionStart` | `idle` | 建立会话 |
| `UserPromptSubmit` | `thinking` | turn 开始 |
| `PreToolUse` | `working` | 工具开始 |
| `PermissionRequest` | `notification` | 原生权限请求 |
| `PostToolUse` | `working` | 工具结束仍工作 |
| `Stop` | `codex-turn-end` | turn 结束 |

来源：[`agents/codex.js#L10-L18`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex.js#L10-L18)、[`hooks/codex-install-utils.js#L20-L40`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-install-utils.js#L20-L40)。普通 handler timeout 为 30 秒，`PermissionRequest` 为 600 秒。

OpenAI 当前规范还提供 `SubagentStart`、`SubagentStop`、`SessionEnd` 等事件，并规定同一事件的多个 matching command hooks 并发执行；因此 Clawd 和 Health Token 可以同时注册，不存在“Clawd 监听后占用了 Codex”的排他关系。[OpenAI Hooks：runtime / lifecycle](https://developers.openai.com/codex/hooks#hooks)

### 2.2 安装与修复策略

Clawd 的安装器：

- 优先使用 `CODEX_HOME`，否则是 `~/.codex`；
- 自动合并 `hooks.json`，只按自己的 script marker 更新/删除自己的 command，保留第三方 hook；
- 缺少 `[features].hooks` 时补 `hooks = true`；显式 `false` 在普通自动同步中被尊重，只有明确 repair 的 `force` 才覆盖；
- 迁移 deprecated `codex_hooks`，保留显式布尔意图；
- 原子写入 hooks JSON，卸载时可带 backup；
- 新增或改变 hook 后明确提示用户在 Codex CLI 运行 `/hooks` 审核。

来源：[`hooks/codex-install-utils.js#L20-L48`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-install-utils.js#L20-L48)、[`#L364-L450`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-install-utils.js#L364-L450)、[`#L567-L744`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-install-utils.js#L567-L744)、[`#L746-L784`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-install-utils.js#L746-L784)。

Codex 的 trust 不是 Clawd 自行生成的。OpenAI 规定非 managed command hook 要审核当前 definition hash；新增或修改后会被跳过，直到用户在 CLI `/hooks` 中信任。[OpenAI Hooks：Review and trust hooks](https://developers.openai.com/codex/hooks#review-and-trust-hooks)

### 2.3 hook 运行时

`codex-hook.js` 从 stdin 读取 Codex hook JSON，将生命周期转换为本地状态 POST；`SessionStart` 第一次 POST 失败时，可以按用户配置启动 Clawd、等待本地服务就绪，再重建并重试该事件。[`hooks/codex-hook.js#L405-L477`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-hook.js#L405-L477)、[`#L648-L718`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-hook.js#L648-L718)

为了判断 Desktop 来源与 Subagent 角色，hook 会从 `transcript_path` 以 8 KiB chunk 读取完整第一条 `session_meta`，最多 256 KiB，而不是猜一个很小的固定 prefix。[`hooks/codex-hook.js#L43-L50`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-hook.js#L43-L50)、[`#L121-L175`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-hook.js#L121-L175)

`PermissionRequest` 是 Clawd 特有产品职责：它把经过限制的请求送到 `/permission`，最长等待约 590 秒，只把白名单 allow/deny 结构写回 stdout；任何解析或传输失败都输出 `{}`，交还 Codex 原生流程。[`hooks/codex-hook.js#L293-L335`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-hook.js#L293-L335)、[`#L337-L402`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-hook.js#L337-L402)、[`#L479-L496`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-hook.js#L479-L496)。Health Token 不需要复制权限代理。

## 3. JSONL fallback：为什么 Clawd 能读到

### 3.1 session ID 首先来自文件名

Clawd 新跟踪一个文件时，先从标准 rollout 文件名最后五段提取 UUID，立即建立 `codex:<uuid>` session；它并不等待 `session_meta.payload.id`。[`agents/codex-log-monitor.js#L1178-L1209`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1178-L1209)、[`#L1805-L1814`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1805-L1814)

`session_meta` 随后补 `cwd`、originator、source 和 root/Subagent 分类；它不是会话存在性的唯一锚点。[`agents/codex-log-monitor.js#L1622-L1630`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1622-L1630)、[`#L1777-L1789`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1777-L1789)

本机只读验证（不记录 prompt/tool 内容）：

- 最新 rollout 文件名中的 UUID 与 `session_meta.payload.id` 相等；
- 第一条 metadata 为 44,217 bytes；
- 它来自 `codex_work_desktop`，并带 `source.subagent.thread_spawn.parent_thread_id`；
- Health Token 当前 `maxSessionMetadataBytes` 和 `maxRecordBytes` 都是 32 KiB。

Health Token 的启动路径在 32 KiB 内找不到第一条换行就返回 `nil`，之后 cursor 没有 session ID；稳态只有再次读到 `session_meta` 才能建立 context，普通 tool record 在 `sessionID == nil` 时直接跳过。[`CodexRolloutMonitor.swift#L19-L50`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenCore/CodexRolloutMonitor.swift#L19-L50)、[`#L297-L341`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenCore/CodexRolloutMonitor.swift#L297-L341)、[`#L462-L518`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenCore/CodexRolloutMonitor.swift#L462-L518)、[`#L584-L635`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenCore/CodexRolloutMonitor.swift#L584-L635)

这就是当前 “Clawd 火热感知，Health Token 需连接” 的直接原因。

### 3.2 轮询、会话发现和预算

Clawd `start()` 立即 poll，随后每 1,500 ms poll。[`agents/codex-log-monitor.js#L206-L226`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L206-L226)

它同时发现：

- 本地今天、昨天、前天的目录；
- 最近存在的 7 个日期目录，用于时区漂移与 resume；
- 整棵年月日树中仍有 5 分钟内写入的旧日期目录，解决 Desktop 长对话持续写回最初日期目录的问题；这棵树以每轮最多 16 次发现操作增量遍历，不阻塞主进程。

来源：[`agents/codex-log-monitor.js#L943-L968`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L943-L968)、[`#L973-L1087`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L973-L1087)、[`#L1089-L1146`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1089-L1146)。

主要常量：

| 边界 | Clawd 固定值 |
| --- | ---: |
| active session mtime window | 5 min |
| tracked files / retired trackers | 50 / 100 |
| partial line | 64 KiB |
| 单文件单次 read | 4 MiB |
| 每 poll 请求总量 | 16 MiB |
| 每 poll file attempts | 64 |
| replay work | 40（background 32） |

来源：[`agents/codex-log-monitor.js#L34-L61`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L34-L61)。这些是 Clawd 的产品负载选择，不应机械照搬；Health Token 应保留更小预算，但不能用“超过一次预算就丢掉整个 session context”的方式实现。

### 3.3 增量读取与文件变化

Clawd 每个 tracker 维护 byte offset，只提交最后一个完整换行之前的 bytes；不完整尾行留在磁盘，下次整体重读。tracker 被 LRU 淘汰后，轻量 read-position ledger 仍在本进程内保留，避免再长时间运行时重放。[`agents/codex-log-monitor.js#L164-L195`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L164-L195)、[`#L1280-L1366`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1280-L1366)

它用 inode/dev（fallback 为 birthtime）识别同路径换文件；identity 变化或 size 小于 offset 时 rebaseline，而不是把旧状态继续套在新文件上。[`agents/codex-log-monitor.js#L1167-L1175`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1167-L1175)、[`#L1570-L1582`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1570-L1582)

### 3.4 历史回放防护

Clawd 有两层 replay guard：

1. 带 timestamp 的旧行，早于 monitor start 约 1.5 秒时不发可见回调；
2. 初次 attach 到 monitor 启动前已存在的文件时进入 backfill，静默重建内部状态，扫描结束最多合成一次当前持续状态（只允许 `thinking`/`working`），不会重放一次性 attention/celebration。

来源：[`agents/codex-log-monitor.js#L5-L15`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L5-L15)、[`#L61-L66`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L61-L66)、[`#L1233-L1238`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1233-L1238)、[`#L1640-L1648`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1640-L1648)、[`#L1920-L1964`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1920-L1964)。

## 4. Subagent、Plan 与工具状态来自哪里

Clawd 的 official hook 表本身没有 `SubagentStart/Stop`；它从 hook payload 或 rollout `session_meta` 的结构化 source/role/parent 字段分类。`source.subagent`、agent role/type 或 parent session/thread id 都可以作为信号；一旦 session 被升级为 Subagent，不会被后续 root 信号降级。分类 LRU 容量 100。[`hooks/codex-subagent-fields.js#L21-L95`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/codex-subagent-fields.js#L21-L95)、[`agents/codex-subagent-classifier.js#L12-L87`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-subagent-classifier.js#L12-L87)

JSONL 映射将 `function_call`、`custom_tool_call`、web search、exec/patch end 等归为 working；`task_started/user_message` 为 thinking，`context_compacted` 为 sweeping，`task_complete` 按本 turn 是否有工具或 assistant output 解析为 attention/idle。[`agents/codex.js#L19-L37`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex.js#L19-L37)、[`agents/codex-log-monitor.js#L1707-L1750`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1707-L1750)

Clawd 没有单独名为 “Plan” 的 UI 信号；Plan 若以 tool/function/custom-tool record 出现，会进入 working。Health Token 已有自己的 `planUpdated` 与 qualifying-tool 规则，不应删除，只需保证底层 rollout 能稳定锚定 session。

## 5. 启动恢复

Clawd 的恢复面向桌宠的待回答卡片，范围明显大于 Health Token 所需：

- 一次性启动 sweep，最多 20 个文件、head+tail 总读预算 20 MiB；
- 第一行必须完整读取，head 上限 256 KiB；
- tail 只读最多 1 MiB，寻找仍未匹配 output 且未被 task completion/abort 关闭的 `request_user_input`；
- pending 最长保留 24 小时，同时检查文件 mtime 和请求自身 timestamp；
- 读取前后复核 file identity/size/mtime，避免并发增长或替换形成混合快照；
- Subagent 不显示 user-input card。

来源：[`agents/codex-log-monitor.js#L67-L104`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L67-L104)、[`#L362-L515`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L362-L515)、[`#L622-L650`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L622-L650)、[`#L684-L903`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L684-L903)。

Health Token 只需要健康提醒，现有“最多恢复 2 分钟内可证明未解决的 root attention”更符合隐私和低打扰目标；应借鉴完整行与快照复核，不应复制 Clawd 的 24 小时卡片恢复。

## 6. 两路事件如何去重

Clawd 不是简单把 hook events 和 rollout events 拼接：

1. official activity 按 session + 可选 turn ID 记录，TTL 10 分钟；最多 200 sessions，每 session 最多 8 个 exact turn marks。[`src/codex-official-activity.js#L5-L18`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/codex-official-activity.js#L5-L18)、[`#L51-L88`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/codex-official-activity.js#L51-L88)
2. official 已覆盖的 JSONL event 在该窗口被抑制；但如果 official `Stop` 漏失、runtime 仍显示 working-like，JSONL `task_complete` 被允许穿透以收尾。[`src/agent-runtime-main.js#L14-L37`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/agent-runtime-main.js#L14-L37)、[`#L104-L130`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/agent-runtime-main.js#L104-L130)
3. turn fence 进一步阻止已结束 turn 的迟到 working、重复 terminal、不同 turn 的 stale terminal；上限 200 sessions、512 个 closed-turn tombstones。[`src/codex-turn-fence.js#L5-L21`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/codex-turn-fence.js#L5-L21)、[`#L97-L167`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/codex-turn-fence.js#L97-L167)
4. rollout monitor 自身也抑制连续相同的 `working`。[`agents/codex-log-monitor.js#L1759-L1774`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/agents/codex-log-monitor.js#L1759-L1774)

Health Token 当前把 `hookEvents + rolloutEvents` 按时间排序后逐条送给 engine，没有 source/turn 去重；同一工具被两路观察到时，tool streak 可能被重复推进。[`HydrationAppModel.swift#L89-L131`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenApp/HydrationAppModel.swift#L89-L131)、[`HydrationEngine.swift#L377-L424`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenCore/HydrationEngine.swift#L377-L424)

## 7. 健康状态不是“最近有没有事件”

Clawd 有三层证据：

### 7.1 静态配置健康

Doctor 检查：Codex/配置是否存在、hook 是否注册、command path 是否有效、`[features].hooks` 是否关闭、每个 Clawd hook position 是否存在 trust record。trust ID 来自 `hooks.json absolute path + snake_case event + group index + handler index`。[`src/doctor-detectors/codex-features-check.js#L35-L91`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/doctor-detectors/codex-features-check.js#L35-L91)、[`#L109-L223`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/doctor-detectors/codex-features-check.js#L109-L223)

### 7.2 运行时到达验证

连接测试窗口只把本地 HTTP 服务真正 accepted 的 hook event 标为 `http-verified`。如果 rollout file mtime 变化但没有 HTTP hook 到达，它会区分 `needs-review`、HTTP blocked/dropped 或 no activity。[`src/doctor-hook-activity.js#L135-L184`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/doctor-hook-activity.js#L135-L184)、[`#L187-L222`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/doctor-hook-activity.js#L187-L222)

### 7.3 用户提示去重

Clawd 将 feature-disabled、needs-review、not-registered、broken-path 分成稳定 signature；启动提醒只在 signature 边沿变化时出现，同一问题不会每次启动重复 nag。[`src/codex-hook-health.js#L22-L68`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/codex-hook-health.js#L22-L68)、[`#L118-L141`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/codex-hook-health.js#L118-L141)

Health Token 当前把 hook count 与 rollout count 合并成一个 `lastObservedAt`，两分钟内任一来源有事件就称 `.connected`；应用重启后内存 evidence 清空，正常空闲也会显示“Codex 需连接”。[`HydrationAppModel.swift#L23-L51`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenApp/HydrationAppModel.swift#L23-L51)、[`#L246-L254`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenApp/HydrationAppModel.swift#L246-L254)、[`#L284-L307`](https://github.com/Cobb04/health-token/blob/db6c34b922edd86670de0d145246ae99fd14441d/Sources/HealthTokenApp/HydrationAppModel.swift#L284-L307)

## 8. Clawd 有可供 Health Token 直接复用的本地接口吗？

Clawd 的本地 server 只绑定 `127.0.0.1`，候选端口为 23333–23337；实际端口/owner PID 写入 `~/.clawd/runtime.json`。hook 先尝试 runtime port，再探测候选端口。[`hooks/server-config.js#L6-L20`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/server-config.js#L6-L20)、[`#L340-L395`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/server-config.js#L340-L395)、[`#L428-L449`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/server-config.js#L428-L449)、[`#L776-L827`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/hooks/server-config.js#L776-L827)

对外 route 只有：

- `GET /state`：只返回 `{ok, app, port}` 的健康探测；
- `POST /state`：hook 写入状态；
- `POST /permission`：权限请求。

来源：[`src/server.js#L716-L759`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/server.js#L716-L759)、[`src/server-route-state.js#L138-L145`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/src/server-route-state.js#L138-L145)。

**没有一个受支持的 GET/session stream 让第三方读取 Clawd 已归一化后的 Codex 状态。** Health Token 若探测其 Electron 内部状态，会依赖未承诺的内部实现、强制用户同时运行 Clawd，也触及许可证边界。因此正确复用层级是“独立读取同一个 Codex source”，不是“读取 Clawd 结果”。Health Token 现有 file inbox 也比复制 localhost server 更简单、更私密。

## 9. 与 Health Token 的精确差距

| 维度 | Clawd | Health Token 当前 | 影响 |
| --- | --- | --- | --- |
| polling | 1.5 s | 1 s | Health Token 已足够快 |
| session ID | 先从标准 filename UUID 建立 | 必须解析 `session_meta.payload.id` | 44,217-byte metadata 直接让 HT 失明 |
| first metadata | hook/recovery 完整行最多 256 KiB；live reader 可读当前 44 KiB | metadata 与 record 均 32 KiB | Desktop/Subagent metadata 超限 |
| discovery | today-2 + recent 7 + 增量发现活跃旧目录 | 递归扫描，512 entries，最多 8 个、mtime 10 min | 大量历史目录下可能饿死长期旧日会话 |
| steady-state read | chunk/offset/完整换行；4 MiB/file read | 一轮新增超过 64 KiB 就 fail closed 到 EOF | 大输出期间可能丢下一批 lifecycle |
| source dedupe | session+turn TTL + turn fence + completion rescue | 两路 events 直接拼接 | tool streak 可能重复计数或迟到事件反转状态 |
| health | config/trust/runtime/file activity 分层 | 最近 2 分钟任一事件 | 空闲误报“需连接”，rollout 也伪装 hook connected |
| hook feature/trust | 识别 false、trust positions、实际 HTTP arrival | 只看自己的 command 是否完整存在 | “写入 hooks.json”被误当成“可执行” |
| local transport | 私有产品内部 HTTP | 小型本地 inbox | HT 无需复制 HTTP server |

## 10. clean-room 实施清单

以下按最小可验证路径排列，描述行为和测试，不复制 Clawd 的源码表达、函数结构或测试 fixture。

### P0：先让真实 Codex 稳定可见

- [ ] 从标准 `rollout-...-<UUID>.jsonl` 文件名严格提取 UUID，在 attach 时立即种入 cursor；只接受规范 UUID 形状。
- [ ] 如果后续完整 metadata 也提供 `payload.id`，校验它与 filename ID 一致；不一致则对该文件 fail closed，不能把两个 session 合并。
- [ ] 将“会话 ID”和“角色已验证”拆开：filename 可以证明 ID，只有完整 metadata 可以证明 Subagent/parent；角色未知时不发 role-sensitive 的 C 升级。
- [ ] first-line metadata 使用独立、有界、必须读到换行才解析的 reader；预算至少覆盖已观察到的 44,217 bytes，并以真实超长 metadata 回归。建议独立上限 256 KiB，但不复制 metadata 内容到持久化。
- [ ] steady-state 改为每轮读取至预算，而不是 `available > maxBytesPerFile` 时把 offset 跳到 EOF；只提交完整换行，partial 留待下轮。
- [ ] oversized/malformed 单条记录只作废该条及其相关 correlation；恢复到下一个可信换行后继续，不能无条件清空整个 session ID。

### P0：避免 hooks 与 rollout 双计数

- [ ] 在内存 observation envelope 中保留 `source = hook|rollout` 与可用的 `turnID/callID`；不要把这些私密或高基数字段写进 hydration persistence。
- [ ] 对 hook 已覆盖的同 session/turn rollout lifecycle 做 bounded TTL suppression。
- [ ] 保留 completion rescue：只有当前 session 仍处于 agent-working/due-strong 候选状态且 official terminal 未到达时，允许 JSONL completion/abort 收尾。
- [ ] 加 terminal fence：closed turn 的迟到 tool、重复 completion、其他 turn 的 stale terminal 不能复活或污染 tool streak。

### P0：把健康文案建立在可操作证据上

- [ ] 状态至少拆为 `rolloutReady`、`hookConfigured`、`hookNeedsReview`、`hookVerified`、`hooksDisabledByUser`、`unavailable/error`。
- [ ] “监听目录可读但尚无事件”显示“已就绪/空闲”，不显示“需连接”。
- [ ] rollout 活动不能把 official hook 标为 verified；只有本次运行真实 inbox hook event 可以。
- [ ] 读取 `[features].hooks` 和 `[hooks.state]` 作只读诊断；绝不写 `trusted_hash`、绝不使用 trust bypass。
- [ ] 需要审核时准确指引“Terminal 启动 Codex CLI → `/hooks`”，不要让用户在 Desktop 对话里输入不存在的命令。

### P1：长时间运行与旧日会话

- [ ] 保留 today/recent 快路径，并以小预算增量发现“写入仍活跃、但文件留在旧日期目录”的 Desktop session。
- [ ] cursor 增加 file identity 与 truncation/replace 处理；新 inode 不继承旧 session/correlation。
- [ ] tracker 淘汰后保留有限 read-position ledger，避免同一进程内重新 attach 后重放。
- [ ] 启动 backfill 只允许合成持续中的工作信号；绝不重放旧 attention、旧 C 或完成庆祝。
- [ ] 保留 Health Token 自己的 2 分钟 root-attention 恢复边界，不复制 Clawd 24 小时权限卡策略。

### 验证矩阵

- [ ] 44,217-byte Desktop/Subagent `session_meta` + 后续 live tool 能生成正确 session/parent event。
- [ ] filename ID / metadata ID mismatch fail closed。
- [ ] metadata 超上限或缺少换行时，不把 Subagent 猜成 root。
- [ ] 一轮 append >64 KiB 后，后续 plan/tool/completion 仍会被观察。
- [ ] hook + rollout 同一 tool 只推进一次 streak。
- [ ] official Stop 漏失时 JSONL completion 能收尾；已收到 Stop 时不会双收尾。
- [ ] 旧日期目录中的活跃 Desktop rollout 可在呈现 SLA 内发现。
- [ ] 文件 truncate、replace、partial UTF-8、malformed/oversized record 不重放历史、不崩溃。
- [ ] 空闲重启显示“已就绪”，实际 feature off / trust missing / path broken 才给出相应动作。
- [ ] 真机验收：root prompt → plan → 三次 qualifying tool → Subagent → needs-user → completion，每一步状态与一口饮水记录互不串扰。

## 11. AGPL 与隐私边界

Clawd 当前源代码是 `AGPL-3.0-only`。[`LICENSE#L1-L18`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/LICENSE#L1-L18)、[`package.json#L72`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/package.json#L72)、[`README.md#L367-L375`](https://github.com/rullerzhou-afk/clawd-on-desk/blob/f0745407727dedf9f701e9e01bb9ac64b6e378bc/README.md#L367-L375)

本笔记只记录外部行为、数据契约、边界和失败模式。实施时应：

- 依据 OpenAI 的 hook contract 与本项目独立测试重新实现；
- 不复制 Clawd 函数、控制流、注释、测试或 UI；
- 不链接/内嵌 Clawd 代码，除非项目明确决定接受 AGPL 发布义务；
- 不读取 Clawd 为桌宠/权限功能采集的 prompt、tool input、assistant output、cwd 或 transcript；
- Health Token 持久化继续只保留最小 `AgentEvent` 与 hydration 数据。

这不是法律意见；它是当前工程的 clean-room 风险边界。

## 最终判断

“既然 Clawd 能成功，我们没理由失败”是正确的工程判断。它成功的决定性细节不是更神秘的 hook，而是：

1. rollout filename 先锚定 session；
2. metadata 读取完整且有更现实的上限；
3. 长期旧目录仍会被发现；
4. hook/rollout 用 session+turn 去重并允许 completion rescue；
5. health 只对真实证据下结论。

Health Token 应 clean-room 复现这五项，并保留自己更小的隐私面、1 秒呈现频率和不替用户处理权限的产品边界。
