# DSH 最小客户端契约（L0 逆向结果）

> 目标：不依赖浏览器内核版本的自研客户端，用最少 API 完成「列会话 / 建会话 / 发消息 / 读消息」。
> 所有结论均在 dsh 0.2.2-rc.1 实测（PC 独立实例 127.0.0.1:61399）。

## 1. 鉴权

```
GET /?token=<launchToken>        → 303 See Other + Set-Cookie: dsh-auth-*（HttpOnly, SameSite=Strict, 30 天）
GET /                            → 200（带 cookie）/ 401（不带）
```

token 由服务端启动时打印：`dsh web: http://127.0.0.1:PORT/?token=XXXX`。
客户端只需第一次带 token 访问，之后依靠 cookie。

## 2. RPC 信封

传输：**HTTP POST，逐方法一次性**（不是 WebSocket）。

```
POST /api/<namespace>/<method>
Content-Type: application/json

{ "type": "client-request", "rpcId": "<uuid>", "method": "<namespace>/<method>", "payload": { "args": { ... } } }
```

响应：

```json
{ "type":"server-response", "rpcId":"...", "result": { "ok": true,  "value": ... } }
{ "type":"server-response", "rpcId":"...", "result": { "ok": false, "error": { "code":"...", "message":"...", "details":{} } } }
```

**三个硬约束（踩过的坑）**：

| 约束 | 说明 |
|---|---|
| 端点是 **两段** `namespace/method` | `session/list` 可以，`remote.session.list` / `session.list` 都 404 |
| payload 必须包一层 `{ args: {...} }` | 直接放字段会报 `Remote payload must contain exactly one plain-object args field` |
| args 是**命名参数**，首参名多为 `request` | 多余字段会被拒：`unexpected "cwd"`；缺字段会提示 `missing "request"` |

## 3. 命名空间（服务端实测）

`account` `credentials` `directoryPicker` `fileReferences` `job` `session` `settings` `skills` `terminal` `workspace`

## 4. 已验证可用的方法

### session/list —— 列会话（含统计）

```jsonc
// 请求
{ "type":"client-request", "rpcId":"...", "method":"session/list", "payload": { "args": { "_request": {} } } }
```

`_request` 表示"无请求参数"；换成字段会报 missing `_request`。

返回（节选真实数据）：

```json
{ "ok": true, "value": { "items": [ {
  "sessionId": "session-...",
  "updatedAt": 1794153254684,
  "running": false,
  "blank": false,
  "cwd": "E:\\deepseekharness工作区\\正在使用",
  "projections": { "values": {
      "title": "dsh安卓运行可行性探讨",
      "tokenUsage": { "uncachedInputTokens": 474559, "outputTokens": 266113, "cacheReadTokens": 75632384 }
  } }
} ] } }
```

→ **L0 的会话列表页只需这一个调用**，标题、运行状态、cwd、token 统计全有。

### session/create —— 建会话

```jsonc
{ "method":"session/create", "payload": { "args": { "request": { "cwd": "/sdcard/DSH/workspace" } } } }
```

返回：`{ "ok": true, "value": { "sessionId": "session-...", "agentPreset": "standard" } }`

可选项：`workspaceId`（替代 cwd）、`sessionId`（复用空白会话）、`agentPreset`。

### session/prompt —— 发消息

```jsonc
{ "method":"session/prompt", "payload": { "args": { "request": {
    "requestId": "<uuid>",
    "sessionId": "session-...",
    "mode": "queue",                       // queue=排队；steer=插话打断当前回合
    "content": [ { "type": "text", "text": "只回复两个字：OK" } ],
    "clientTimeZone": "Asia/Shanghai"
} } } }
```

返回：`{ "ok": true, "value": { "accepted": true } }` —— 注意这是**已接收**，不是已完成。

### 其他已确认存在的端点

`session/cancel` `session/rename` `session/page` `session/projections` `session/follow`
`workspace/*` `workspaceFiles/stat` `workspaceFiles/changes` `job/list` `job/kill` `job/follow`
`commands/execute` `terminal/*`

## 5. 读回消息：session/page（已打通）

游标来自 `session/list` 每一项的 `projections.asOfSeq`。

```jsonc
{ "method":"session/page", "payload": { "args": { "request": {
    "address": { "kind": "session", "sessionId": "session-..." },   // 子代理会话则是 { kind:"subagent", parentSessionId, childSessionId }
    "throughSeq": 19,        // = asOfSeq；-1 表示"从头之前"，返回空
    "maxMessages": 10,
    "beforeSeq": 0           // 可选，向前翻页
} } } }
```

返回事件流（实测节选）：

```json
{ "ok": true, "value": { "records": [ { "type":"event", "event": {
    "type":"assistant/attempt", "seq":17, "time":1794154143652,
    "data": { "turn":1, "step":1, "stream":[
        { "type":"chunk", "chunk": { "type":"text", "text":"…" } },
        { "type":"chunk", "chunk": { "type":"finish", "reason":{ "kind":"ok" } } }
    ] }
} } ], "hasMore": false } }
```

已知事件类型：`user/message`、`assistant/attempt`（含 `data.stream` 分块）、`step/end`、`turn/end`（`reason.kind` = ok/error）、以及标题生成等内部 LLM 事件（可按 `source.kind` 过滤掉）。

**读新消息的方式**：再次用更大的 `throughSeq`（新一轮的 asOfSeq）重读，或用 `session/page` 拿到的最大 `seq` 增量轮询。

## 6. 错误响应即契约文档

参数不对时服务端会精确报错，可直接当文档用：

| 错误 | 含义 |
|---|---|
| `Remote payload must contain exactly one plain-object args field` | 忘了包 `{args:{...}}` |
| `args fields do not match the descriptor: unexpected "cwd"` | 字段放错了层级（cwd 要在 `request` 里） |
| `missing "request"` / `missing "_request"` | 该方法首参必须给；无参方法用 `_request: {}` |
| `wire field "request" failed boundary validation` | request 内部结构不对（例如 address 缺 `kind`） |

## 7. L0 客户端的落地形态

```
assets/mini-client/index.html    单文件，ES2017 语法，无构建
  ├─ 会话列表   → session/list（已验证）
  ├─ 新建会话   → session/create（已验证，cwd 由 App 传入 /sdcard/DSH/workspace）
  ├─ 发送消息   → session/prompt（已验证）
  └─ 显示回复   → session/page（已验证，轮询 asOfSeq 增量）
```

App 侧只做两件事：把 token/工作区注入这个页面（`loadDataWithBaseURL` 或 query 参数），以及把页面放进 WebView。
这样即便目标机 WebView 只有 Chromium 60，也能跑——因为页面是我们写的、语法目标 ES2017，不用 dsh 官方 SPA。
