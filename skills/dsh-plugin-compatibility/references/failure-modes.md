# 失败模式：跳过 / 崩树 / 静默失效

同一个"闸不过"，后果差别很大。**先定性，再处置**——搞错会白修或漏修。

## 三种模式

| 模式 | 触发 | 现象 | 处置 |
|---|---|---|---|
| **被跳过**（安全） | 闸一不过（peer 范围不满足） | 插件页显示「异常 / 不兼容」；该 bundle 进 `skippedBundles`；运行时里没有它的 entry；**DSH 正常、聊天记录正常** | 改 peer 范围（见 `facts-dsh-*.md`），或**接受现状**（插件不生效但无害） |
| **崩树**（致命） | 闸二不过（清单契约错）且**在激活期已挂载** | `dsh web` 起不来 / 界面在但**聊天记录整个看不到**；日志里有 `typert contributor(s) failed to register` / `AggregateError` | **先恢复**（`upgrade-runbook.md`），再修清单 |
| **静默失效** | 闸二不过，但插件在**激活之后**才挂载 | 树活着、entry `active`、UI 看着正常，**但该插件的宿主远端端点没注册**——涉及它的功能点了没反应或报错 | 体检脚本一样会 ❌；按崩树同样的方式修清单 |

## 为什么同一个清单错会有两种后果

`typert-loader` 自己的文档写得很直白：

> 明确声明的包或 artifact 坏了 → 在**激活时 fail loud**（聚合成本插件的 activation throw）；
> 在**稳态**则 **contained to a logged error per package**。

即：**分界是"这个 entry 在 typert-loader 激活那一刻是否已经挂载"**，不是"清单错得有多严重"。

## ⚠️ 未定论：分界的确切条件尚未定位

本项目实测到一个**尚未解释清楚**的现象（必须诚实记录，别当成已解决）：

- `dsh-icon-custom`：清单闸二 ❌、entry `active`、**DSH 一直没崩**；
- `dsh-model-fit@0.2.1`：清单闸二 ❌、entry `active`、**整棵树崩了**；
- 两者都是 link 安装的 profile bundle、都导出 `./typert`、都在同一份 bundle 列表里，差异没能定位到确切条件。

两种可能的解释（都未证实）：挂载时序不同；或 model-fit 那次崩溃还有别的成因。

**因此实践上唯一安全的立场是：**

> 体检 ❌ 一律修，**不要因为"它现在没崩"就认为清单没问题**。
> 反过来，看到"树崩了"也不要只盯清单——先按 `upgrade-runbook.md` 恢复，再用脚本定位。

把这条定论钉死需要一次受控实验：在 scratch profile 里真启动一个"清单故意写坏"的插件，观察走哪个分支。见 `upgrade-runbook.md` 第 4 步。

## 识别信号速查

```bash
# 是否被跳过（闸一）
node scripts/check-plugin.mjs <插件目录>            # 闸一 FAIL 即"会被跳过"

# 插件到底挂载没有（看 fiberPhase，别看 Service 目录）
#   plugin_manager list_plugins → 找 moduleName == 插件包名，fiberPhase: "active" = 已挂载

# 客户端半边有没有加载
#   cordis_inspect_query(client, Slots, listSubTree, {"root":"settings.section"}) → occupants 里有你的 id

# 闸二
node scripts/check-plugin.mjs <插件目录>            # 闸二 FAIL 即"清单不合法"
```
