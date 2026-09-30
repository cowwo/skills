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
| `dsh-provider-info@0.16.0` | ✅ | ❌ 8 处 `schema:` | 首个报错 `providerBadge/modelInfo parameter codec`；**0.17.0 已修，实测 ✅（4 invocation / 8 codec）** |
| `dsh-icon-custom@0.8.0` | ✅ | ❌ 11 处 `schema:` | `iconCustom/getStatus result codec`。**0.8.1 / 0.8.2 已修并发布**（7 invocation / 11 codec）。0.8.0 当年是 `latest` —— 坏版本发出去只能靠升版本收场 |
| `dsh-notify-p@0.1.0` | ✅ | ❌ 2 处 `schema:` | `mailNotify/test result codec` |
| `dsh-session-title-pro@0.1.0` | ✅ | ❌ | `sessionTitlePro/preview parameter codec` |
| `dsh-session-failure@0.1.0` | ✅ | ❌ 2 处 `schema:` | `sessionFailure/lastFailures parameter codec` |

### 已定位：闸二失败到底打死了哪一半（`dsh-icon-custom` 复盘）

闸二失败**不会**让插件整个失效，它只打死 **typert RPC 端点**。同一插件里走别的注册途径的宿主副作用照常生效：

- ❌ 死的：`iconCustom/*` 全部 7 个端点（`getStatus`/`setIcon`/`setPwa`/`setLogo`/`resetIcon`/`getUnreadRule`/`setUnreadRule`）→ 设置页读不到状态、上传/重置/开关全部无反应。
- ✅ 活的：`ctx.webServer.register` 注册的 HTTP 路由（`/icon-custom.svg`、`/manifest.webmanifest`、派生 PNG）与 `tapIndex` 头部改写（都不经 typert）→ 已保存的图标**继续照常服务**。

所以"图标还能显示、但设置页点了没反应"正是静默失效的指纹，别因为 HTTP 路由 200 就以为插件是好的。

**未定论（部分收窄）**：`dsh-icon-custom` 闸二 ❌ 且 entry `active`，DSH 一直没崩；而 `dsh-model-fit@0.2.1` 同样条件却崩了整棵树。读 `typert-loader` 的 `apply()` 可见分界**应当**是"该 entry 在 loader 激活那一轮扫描时是否已在 `ctx.loader.entries()` 里"：在 → `await Promise.all(flush())` 收进 `failures` → 抛 `AggregateError`（崩树）；在那之后才挂载 → 走 `ctx.on("internal/plugin")` 的微任务分支 → 只 `ctx.logger.error`（contained）。**但这条尚未经受控实验证实**（两个插件都是 bundle entry，为何走了不同分支仍未解释）。处置立场不变：❌ 一律修。钉死它仍要靠 `upgrade-runbook.md` 第 4 步的 scratch profile 实验。

### 第三类失败：闸一闸二都过，客户端 API 漂移（两闸都抓不到）

`dsh-icon-custom` 0.8.1 两闸全过，但"红点点开不消失"依旧。原因是**客户端半边**（`client/client.js`，跑在浏览器里）读了 0.2.x 已经不存在的东西。**体检脚本与两道闸都管不到客户端，这类只能逐个 prop / 逐个服务方法核对。**

同一个插件里一次抓到三处（升级前都在 0.1.x 存在）：

| 插件用了 | 0.2.x 实际 | 症状 | 0.2.x 正确写法 |
|---|---|---|---|
| `list.current`（会话列表快照） | 快照**只有** `ids` / `byId` / `phase` / `projectionsBySession`（两处写入点实测确认） | 已读水位线永不写入 → **红点点开也不消失** | `Object.values(state.byId).find(s => (s.retainedBy.mainView ?? 0) > 0)?.id` |
| `props.useSessionPendingInteraction` | **全仓 0 匹配**，没有任何地方提供它 | "在等你"那半**从未生效**（静默降级） | `props.useSessionStatus`（map 的值带 `pendingInteraction`，另有官方的 `completionUnread`） |
| `ctx.sessions.open(id)` | `ClientSessions` 没有导航方法 | 待处理列表点进去**不跳转** | `ctx.uiWorkspace.openSession(id)`（ui-chat 就这么写）；用 `ctx.get("uiWorkspace")?.…` 可选查找，别加硬依赖 |

核对方法（`workflow.md` 第 4 步的具体化）：

```bash
DSH=/usr/local/lib/node_modules/@deepseek-ai/dsh
# ① 插件用到的每个 prop 名，在运行时里数匹配数；0 = 没人提供
grep -rc "useSessionPendingInteraction" "$DSH/node_modules/@deepseek-ai"/*/lib/client.js | grep -v ":0"
# ② 判断"该服务有没有这个方法"，要看**类源码的方法列表**，不要只看 inspect 的方法表
#    方法表并不穷尽（它没列 list，官方却在用 ctx.sessions.list.getSnapshot()）
grep -n "= class" "$DSH/node_modules/@deepseek-ai/dsh-api-session-controller/lib/client.js"
# ③ "官方怎么干这件事"最可靠：搜官方插件里的同类调用
grep -rn "uiWorkspace.openSession\|source: \"mainView\"" "$DSH/node_modules/@deepseek-ai"/*/lib/client.js
```

### 第四类：DSH 自己的页面结构变了（两闸 + prop 全过，仍不生效）

`dsh-icon-custom` 修完闸二和三处 prop 漂移后，"替换图标"在**浅色模式**下依然完全不生效——真凶是 DSH 0.2.x 的 `index.html` 内置了**两条** `<link rel="icon">`：

```html
<link rel="icon" type="image/svg+xml" href="./favicon-dark.svg" media="(prefers-color-scheme: dark)" />
<link rel="icon" type="image/svg+xml" href="./favicon.svg"      media="(prefers-color-scheme: light)" />
```

插件两端都只处理 `document.querySelector` 拿到的**第一条**：宿主 `_rewriteIndex` 用**非全局**正则只替换了 dark 那条，light 那条仍是内置 favicon；客户端 `iconLink`/`applyLive`/`applyDefault` 同样只认第一条。而浏览器取「**最后一个**合适候选」→ **浅色模式下内置图标反杀**。

> **指纹：深色模式正常、浅色模式不生效**（或反之）。看到这种"按配色一半好一半坏"，先怀疑插件只处理了多条同类标签中的一条。

判据（直接看真实产物，不要靠记忆）：

```bash
DSH=/usr/local/lib/node_modules/@deepseek-ai/dsh
grep -o '<link[^>]*rel="icon"[^>]*>' "$DSH/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html"
# 改写对不对，也要拿真实 index.html 跑一遍真实函数（大括号配对 eval 出来），别只看代码：
#   断言"改写后只剩 1 条、无 media、href 指向自定义图标"
```

**三条教训**（都踩过）：

1. `index.html` 是 DSH 的产物，升级会变结构。对它做字符串改写（`tapIndex`）或对 head 做 DOM 操作的插件，一律**按"可能有多条"写**（`replace` 用 `/g`，`querySelectorAll` 而不是 `querySelector`）。
2. 插件若承诺"无自定义图标时零副作用"，那条分支必须**还原原始标签**（记住每条的 `href`/`type`/`media` 再放回去），而不是把多条统一改成一个 href——否则深色模式那个图标会被静默改掉。
3. 写入要**幂等**（值相同就别写）：head 上的 `MutationObserver` 会回调 `reconcileFavicon`，冗余写入会让看门狗自激。

两个操作细节：

- `cordis_inspect_query`(client, …) 在**浏览器页面没连上**时会报 `no connected Harness page`——不代表插件坏了，重开页面再试。
- 客户端的修复**必须刷新页面**才生效（宿主修复要重启）——两者是两次独立的加载。

## 判"插件到底挂载没有"的正确信号

| 信号 | 说明 |
|---|---|
| `plugin_manager list_plugins` 里 `moduleName == 插件包名`，`fiberPhase: "active"` | **正面证据：entry 已挂载** |
| `cordis_inspect_query`(client, `Slots`, `listSubTree`, `{"root":"settings.section"}`) 的 occupants | 证明**客户端半边**注册成功（宿主半边独立，不能由它推断） |
| `cordis_inspect_query`(host, `Service`, `listService`) 里查不到插件服务 | **不是证据**：该目录不含第三方服务（本项目用另一个正常插件做过对照） |
| 插件管理页显示"正常" | **不是运行时证据**：页面实时读盘判定，而当前进程可能是在旧状态下启动的 |
