# 方法与重新推导

本文件只讲**与 DSH 版本无关**的做法：怎么找到闸、怎么跑、DSH 升级后怎么刷新事实。

## 1. 定位两道闸（现找，不靠记忆）

校验器都是被 **export 出来的普通函数**，所以能在装着的运行时里按名字搜到：

```bash
# dsh 安装根：先跑一次体检脚本，它第一行就打印解析到的路径；
# 也可以用 --dsh <目录> 或 DSH_INSTALL 指定。
DSH=/usr/local/lib/node_modules/@deepseek-ai/dsh

grep -rl "evaluatePluginCompatibility" "$DSH/node_modules/@deepseek-ai"/*/lib/*.js   # 闸一
grep -rl "validateTypertManifest"      "$DSH/node_modules/@deepseek-ai"/*/lib/*.js   # 闸二
```

`scripts/check-plugin.mjs` 已经把这两个位置写在 `loadLib()` 里（`dsh-app-boot` / `dsh-typert-loader`）。**搜不到时先改脚本的这两个包名**，而不是放弃检查。

## 2. 跑体检（首选）

```bash
node scripts/check-plugin.mjs <插件目录> [更多目录...] [--dsh <dsh安装目录>] [--runtime <版本>]
```

脚本做三件事：跑闸一、跑闸二、并按网关注册后的真实调用路径再走一遍 `codec.create()`。
退出码 `2` 表示它自己找不到闸——回到第 1 步。

## 3. 手工跑闸（没有脚本时）

```bash
node --input-type=module -e "
const DSH = '/usr/local/lib/node_modules/@deepseek-ai/dsh'
const { evaluatePluginCompatibility, getDshRuntimeVersion } =
  await import(DSH + '/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')
const { validateTypertManifest } =
  await import(DSH + '/node_modules/@deepseek-ai/dsh-typert-loader/lib/index.js')
const { readFileSync } = await import('node:fs')

const dir = process.argv[1]
const manifest = JSON.parse(readFileSync(dir + '/package.json', 'utf8'))

console.log('运行时:', getDshRuntimeVersion())
const issue = evaluatePluginCompatibility(manifest)
console.log('闸一:', issue ? 'FAIL ' + JSON.stringify(issue.peers) : 'PASS')

const rel = manifest.exports?.['./typert']
if (!rel) console.log('闸二: 无 ./typert')
else {
  const mod = await import(dir + '/' + rel.replace('./', ''))
  try { validateTypertManifest(manifest.name, mod.TYPERT); console.log('闸二: PASS') }
  catch (e) { console.log('闸二: FAIL', e.message) }
}
" <插件目录>
```

## 4. 脚本管不到的：逐项 API 漂移核对

闸只保证"能进树、清单合法"，**不保证插件调用的 API 还在**。升级 DSH 后，对插件实际用到的每个点核对一遍（改法见 `practices.md` 那类官方文档，这里只列"怎么查"）：

| 用到的东西 | 怎么核对 |
|---|---|
| 基类与服务 | 插件 `extends` 的基类仍从同一包根导出，构造函数签名未变（对比官方同类插件） |
| 宿主服务方法 | 在 `dsh-llm` 之类包的 `lib/index.js` 里搜方法名，确认仍在且有 JSDoc 签名 |
| 远端调用参数 | `settings.mutate` 之类的 op 形状（`{op:'set'\|'unset', path, value}`）仍被接受 |
| 客户端 inject 名 | 只用于**排序激活**，不是 npm 包；对照同 profile 里正常工作的插件是否用同样的名字 |
| 客户端槽位 | `cordis_inspect_query`(client, `Slots`) 查目标槽位的注册参数是否变了 |

## 5. DSH 升级后：重新推导事实

1. `dsh --version` 读出新版本。
2. 按第 1 步重新定位两个校验器，确认函数名与签名。
3. 把新答案写成一个新的 `references/facts-dsh-<新版本>.md`（照抄旧文件的章节结构）。
4. `SKILL.md` 与本文件**不需要改**——它们不含版本事实。
5. 用旧事实文件里的观测量重新对比一遍（例如：之前哪些插件闸二 ❌，升级后是否仍 ❌）。

## 6. 三个假阴性陷阱（本项目实测）

- **`cordis_inspect_query` 的 Service 目录里查不到第三方插件的服务，不能证明它没注册。** 该目录不含第三方服务；用同 profile 里另一个正常插件的服务名做对照即可验证这一点。要判断"插件是否挂载"，应看 `plugin_manager list_plugins` 的 `fiberPhase`（`active` = 已挂载）。
- **客户端槽位里有注册项，只证明客户端半边加载了**，不证明宿主的 typert 端点可用——这两半独立。
- **插件页显示"正常"不代表运行时已生效**：页面是实时读盘重新判定的，可能已判定通过，而当前进程是在旧状态下启动的（改动要重启才生效）。
