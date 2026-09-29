---
name: dsh-plugin-compatibility
description: 判断一个 DSH 插件与当前 DSH 版本是否兼容：插件页显示「异常/不兼容」、dsh web 起不来或聊天记录消失、插件"加载了但功能没反应"，以及发布插件前或升级 DSH 前后使用。跑 DSH 自己在启动/激活时跑的那两道闸（peer 范围、typert 清单），给出修复与恢复步骤。
---

# DSH 插件兼容性 / 防崩

DSH 在**两个不同时刻**、用**两套互不相干的机制**判定一个插件：

| 闸 | 何时 | 判什么 | 不过的后果 |
|---|---|---|---|
| **闸一 · peer 范围** | 启动装载 bundle 时 | `package.json` 里 `@deepseek-ai/dsh` / `@deepseek-ai/dsh-*` 的 peer 范围 | 该 bundle **被跳过**（进 `skippedBundles`）。DSH 照常启动，插件不生效。**安全** |
| **闸二 · typert 清单** | 插件激活时 | `./typert` 导出的 `TYPERT` 清单（strict codec 契约） | `typert-loader` 抛 `AggregateError`：轻则该插件静默失效，重则**整棵插件树加载失败**（起不来 / 聊天记录消失）。**致命** |

**最重要的一条：两闸互相独立，必须分开验。**
闸一过了只说明"能进树"，**不代表激活不会崩**；闸一没过也不代表插件写坏了，只是没被放进来。反过来，把闸一写得过宽（例如 `*`）会撤掉闸二唯一的事前保护——本项目踩过：peer 从 `^0.1.1-rc.2` 放宽到 `*` 后，一直被挡在门外的旧清单立刻显形。

## 先跑体检（一条命令）

```bash
node <本 skill 目录>/scripts/check-plugin.mjs <插件目录> [更多目录...]
```

它**直接调用 DSH 装好的那两个校验函数**，不复制规则，所以 DSH 升级后依然有效。
退出码：`0` = 无致命项；`1` = 有闸二失败；`2` = 脚本找不到检查点（读 `references/workflow.md` 重新定位）。

## 两层结构：方法常青，事实带版本戳

- **方法**（`workflow.md`、`failure-modes.md`、`upgrade-runbook.md`）——与 DSH 版本无关：**从装着的运行时里现找**闸在哪、叫什么，再跑它们。
- **事实**（`facts-dsh-*.md`）——某个 DSH 版本的**具体答案**（路径、函数名、契约写法）。**会过期**。

动手前做一次版本自检：

```bash
dsh --version                            # 当前运行时版本
ls <本 skill 目录>/references/facts-dsh-*.md   # 手里有哪些事实快照
```

若**没有**对应的 `facts-dsh-<当前版本>.md`，先按 `workflow.md` 的「重新推导」刷新事实，再动手——**别信旧版本的事实**。这是本 skill 在 0.5.0 / 1.0.0 上不会静默失效的原因。

## 场景 → 动作

| 场景 | 先做 | 再读 |
|---|---|---|
| 插件页显示「异常 / 不兼容」 | 体检脚本 | 闸一失败 → 按 `facts-dsh-*.md` 的 peer 语义改范围 |
| `dsh web` 起不来 / 聊天记录消失 | **先恢复**，再体检 | `upgrade-runbook.md` 的恢复步骤 + `failure-modes.md` |
| 插件"加载了但功能没反应" | 体检脚本 | `failure-modes.md` 的静默失效分支 |
| 发布插件前 / 升级 DSH 前后 | 体检脚本 | `upgrade-runbook.md` |
| 给一批插件做体检 | 体检脚本（可传多个目录） | — |

## 兜底真理（与版本无关）

静态跑校验器是**早期预警**；最终判据是**在 scratch profile 里真启动一次**——它执行当前 DSH 的真实行为，任何版本都有效。见 `upgrade-runbook.md`。

## 读什么

| 任务 | 文件 |
|---|---|
| 现找闸的位置与函数名、跑校验、DSH 升级后刷新事实 | `references/workflow.md` |
| 三种失败（跳过 / 崩树 / 静默失效）的识别与处置 | `references/failure-modes.md` |
| 升级前后清单、备份、scratch profile、出事恢复 | `references/upgrade-runbook.md` |
| 当前版本的具体事实（0.2.x 的路径、函数名、`create()` 契约、peer 语义） | `references/facts-dsh-0.2.x.md` |
