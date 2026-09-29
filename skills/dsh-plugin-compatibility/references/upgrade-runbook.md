# 升级 / 发布 runbook

## 原则

- **升级 DSH 前先体检，不要先重启。** 体检不需要动运行中的服务。
- **改动只在重启后生效**：bundle 组合发生在启动时，改 peer / 改清单都不会热生效。
- **恢复路径要提前准备好**：出事的代价是"整个界面用不了"，而恢复动作只有两步。

## 1. 升级 DSH 之前

```bash
# 记录当前状态，便于事后对比
dsh --version
node scripts/check-plugin.mjs <你的插件目录...>      # 记下此刻哪些闸过 / 不过

# 备份 profile 清单（出事时一键还原）
cp "$DSH_PROFILE_DIR/package.json" "$DSH_PROFILE_DIR/package.json.bak-before-<版本>"
```

## 2. 升级 DSH 之后（先别急着重启）

```bash
dsh --version                                   # 新版本
ls references/facts-dsh-*.md                    # 有对应事实文件吗？没有就先重新推导
node scripts/check-plugin.mjs <你的插件目录...>  # 用新运行时重跑两道闸
```

- 闸二出现新的 ❌ → **在重启前**修掉，否则可能重启不起来。
- 闸一出现 FAIL → 插件会被跳过（安全），可以按需修。
- 新版本没有对应事实文件时，先走 `workflow.md` 的「重新推导」。

## 3. 出事时的恢复（30 秒）

症状：`dsh web` 起不来，或界面在但**聊天记录整个看不到**。

```bash
P="$DSH_PROFILE_DIR/package.json"

# ① 从 bundles 列表里摘掉疑似插件
# ② 从 dependencies 里摘掉它（两处都要，缺一处 pnpm 仍会装它）
#    node_modules 里的软链不用管

# ③ 重启 dsh web

# 或者直接还原备份：
# cp "$P.bak-before-<版本>" "$P" && 重启
```

**先恢复、再定位**：服务起来之后才有余力用体检脚本找出是哪个插件、哪道闸。

## 4. scratch profile：唯一与版本无关的兜底验证

静态跑校验器是早期预警；**真启动一次**执行的是当前 DSH 的真实行为。

要点：**另建 profile、另用端口、作为受管后台任务**，验完关掉——不要动正在用的 profile，也不要占它正在用的端口。

```bash
# 从一个内置模板初始化一个 scratch profile（语法以 dsh --help 为准）
dsh <scratch> --from-default-profile web
# 在里面装/启用待测插件，然后用另一个端口启动（启动器参数之后的参数传给 app）
dsh <scratch> --port <另一个端口> --no-open
```

这个手段同时能钉死 `failure-modes.md` 里那条**未定论**：在 scratch profile 里放一个"清单故意写坏"的插件，看它走 **fail loud（崩树）** 还是 **contained（静默失效）** 分支，再看它与挂载位置的关系。

## 5. 发布插件之前

```bash
node scripts/check-plugin.mjs <插件目录>        # 两道闸都必须过
```

体检 ❌ 就不要发：npm 上的坏版本会**被别人装到他们的 DSH 上**，而闸一放宽过（例如 `*`）之后，闸二没有别的事前保护。发布过的坏版本收不回，只能升版本或 `npm deprecate`。
