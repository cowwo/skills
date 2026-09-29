# 事实快照：DSH 0.2.x

> **本文档针对 DSH `0.2.0-rc.1` / `0.2.0-rc.2`（两者闸规则实测一致）。**
> 若 `dsh --version` 不是 0.2.x，**先按 `workflow.md` 的「重新推导」刷新本文，别照抄**。

## 闸一 · peer 范围

| 项 | 值 |
|---|---|
| 函数 | `evaluatePluginCompatibility(manifest, exemptions = {}, runtimeVersion = getDshRuntimeVersion())` |
| 位置 | `<dsh>/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js`（本版约 286 行） |
| 判什么 | 只遍历 peer 名等于 `@deepseek-ai/dsh` 或以 `@deepseek-ai/dsh-` 开头的项 |

规则细节（本版源码实测）：

- 比较用 `semver.satisfies(runtimeVersion, range, { includePrerelease: true })` —— **预发布版参与匹配**。
- `workspace:^` / `workspace:~` / `workspace:*` 视为"当前运行时版本"。
- **`peerDependenciesMeta.optional` 完全不被读取**：标了 `optional: true` 照样拦。
- 非 `@deepseek-ai/dsh-*` 的 peer（`@deepseek-ai/cordis`、`schemastery`、`@earendil-works/pi-ai`）**一律不检查**。
- 宽范围的代价：`*` 能通过任何版本（含未来 0.5.0 / 1.0.0），但它同时**撤掉了闸二唯一的事前保护**——本项目 peer 从 `^0.1.1-rc.2` 放宽到 `*` 后，旧清单立刻显形。所以放宽 peer 必须配一次清单复验。
- `^0.1.1-rc.2` 这类 0.x 范围只允许 patch 位浮动，规范化后是 `>=0.1.1-rc.2 <0.2.0-0`；DSH 升到 0.2 就落到范围外——**0.x 的 caret 上界是升级踩雷的常见原因**。

后果与豁免：

- 启动装载时不过 → 该 bundle 进 `skippedBundles`，插件不挂载，**DSH 正常**。
- 绕过闸一（**只绕过闸一，不解决闸二**）：profile 的 `compatibility.json`，由
  `dsh plugin --profile <name> allow-version <package@version> --dsh-version <exact> --accept-risk` 写入。

## 闸二 · typert 清单

| 项 | 值 |
|---|---|
| 函数 | `validateTypertManifest(pkgName, exported)` |
| 位置 | `<dsh>/node_modules/@deepseek-ai/dsh-typert-loader/lib/index.js` |
| 取清单的键 | `package.json` 的 `exports["./typert"]`（字符串，或带 `default` 字符串的对象） |
| 清单要求 | `manifest.package === 包名`、`face === 'host'`、`schemas` 是数组、`model.{services,events,objects}` 是数组 |

**strict codec 契约（本次崩溃的直接原因）：**

```js
// ✅ 0.2.x 正确写法：create 是**工厂函数**，返回 zod schema
codec: { mode: 'strict', typeSymbol: 'pkg#svc/method:request', create: () => zodSchema }

// ❌ 0.1.x 已死写法：裸 schema 字段
codec: { mode: 'strict', typeSymbol: '…', schema: zodSchema }
```

- 判据在 loader 的 `requireStrictCodec`：`typeof codec.create !== "function"` → 抛
  `... <subject> has no create() factory`（`subject` 形如 `invocation "…" parameter codec` / `result codec`）。
- `typert-registry` 的 `validateCodec` 有同样要求；只有 `mode: 'src-json'` 会提前返回、豁免 `create`。
  但 **loader 对清单里的 codec 强制 `mode: 'strict'`**，所以手写清单没有 `src-json` 这条退路。
- 官方生成物同形（惰性记忆化）：`const X$schema = () => (X$schema$value ??= z.…)`，然后 `create: X$schema`。
- 消费方：网关按 `codec.create().parse(value)` 调用；registry 用 `record.create()` 缓存 schema。

**失败的传播路径（为什么可能崩整棵树）：**

`typert-loader` 的 `apply()` 里 `await Promise.all(flush(...))`；只要有 contributor 注册失败就
`throw new AggregateError(failures, "typert-loader: N typert contributor(s) failed to register: …")`
→ 该核心 entry 挂载失败 → 整棵树加载失败。
稳态（激活之后才挂载的 entry）失败则只走 `ctx.logger.error`，**contained**。

## 实测数据（2026-09-29，rc.2）

| 插件 | 闸一 | 闸二 | 备注 |
|---|---|---|---|
| `dsh-model-fit@0.2.2` | ✅ | ✅ | 已修：2 处 codec 改成 `create: () => …` |
| `dsh-provider-info@0.16.0` | ✅ | ❌ 8 处 `schema:` | 首个报错 `providerBadge/modelInfo parameter codec` |
| `dsh-icon-custom@0.8.0` | ✅ | ❌ 10+ 处 `schema:` | `active` 却未崩树，见下 |
| `dsh-notify-p@0.1.0` | ✅ | ❌ 2 处 `schema:` | `mailNotify/test result codec` |
| `dsh-session-title-pro@0.1.0` | ✅ | ❌ | `sessionTitlePro/preview parameter codec` |
| `dsh-session-failure@0.1.0` | ✅ | ❌ 2 处 `schema:` | `sessionFailure/lastFailures parameter codec` |

**未定论**：`dsh-icon-custom` 闸二 ❌ 且 entry `active`，DSH 一直没崩；而 `dsh-model-fit@0.2.1` 同样条件却崩了整棵树。分界条件尚未定位到——处置立场见 `failure-modes.md`（❌ 一律修，别指望"现在没崩"）。

## 判"插件到底挂载没有"的正确信号

| 信号 | 说明 |
|---|---|
| `plugin_manager list_plugins` 里 `moduleName == 插件包名`，`fiberPhase: "active"` | **正面证据：entry 已挂载** |
| `cordis_inspect_query`(client, `Slots`, `listSubTree`, `{"root":"settings.section"}`) 的 occupants | 证明**客户端半边**注册成功（宿主半边独立，不能由它推断） |
| `cordis_inspect_query`(host, `Service`, `listService`) 里查不到插件服务 | **不是证据**：该目录不含第三方服务（本项目用另一个正常插件做过对照） |
| 插件管理页显示"正常" | **不是运行时证据**：页面实时读盘判定，而当前进程可能是在旧状态下启动的 |
