#!/usr/bin/env node
/**
 * DSH 插件兼容性体检：跑 DSH 自己在启动/激活时跑的那两道闸。
 *
 * 用法:
 *   node check-plugin.mjs <插件目录> [更多目录...] [--dsh <dsh安装目录>] [--runtime <版本>]
 *
 * 退出码: 0 = 无致命项；1 = 有致命项（闸二失败）；2 = 脚本自身无法定位检查点。
 *
 * 设计原则：不复制 DSH 的判定规则，而是**直接调用 DSH 装好的那两个校验函数**。
 * 因此 DSH 升级后本脚本依然有效——它用的是当前运行时的真实规则，不是我们对
 * 某个版本规则的记忆。只有在"找不到闸"时才停，并明确提示去重新定位。
 */
import { readFileSync, existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const USAGE = '用法: node check-plugin.mjs <插件目录> [更多目录...] [--dsh <dsh安装目录>] [--runtime <版本>]'

const argv = process.argv.slice(2)
let dshArg
let runtimeArg
const dirs = []
for (let i = 0; i < argv.length; i += 1) {
	const arg = argv[i]
	if (arg === '--dsh') dshArg = argv[++i]
	else if (arg === '--runtime') runtimeArg = argv[++i]
	else if (arg === '-h' || arg === '--help') { console.log(USAGE); process.exit(0) }
	else dirs.push(arg)
}
if (dirs.length === 0) { console.error(USAGE); process.exit(2) }

/** 定位 dsh 安装根：显式参数 → 环境变量 → 全局安装默认位置。 */
function findDsh() {
	const candidates = [dshArg, process.env.DSH_INSTALL, '/usr/local/lib/node_modules/@deepseek-ai/dsh'].filter(Boolean)
	for (const candidate of candidates) {
		try {
			if (JSON.parse(readFileSync(join(candidate, 'package.json'), 'utf8')).name === '@deepseek-ai/dsh') return candidate
		} catch { /* 试下一个候选 */ }
	}
	throw new Error('找不到 dsh 安装目录——用 --dsh <目录> 指定 dsh 包的根（含 package.json 的那层）')
}

const DSH = findDsh()
const pkgs = join(DSH, 'node_modules', '@deepseek-ai')

/** 导入一个 dsh 包已装好的 lib 入口，返回该模块的全部导出。 */
async function loadLib(pkg, file) {
	const path = join(pkgs, pkg, 'lib', file)
	if (!existsSync(path)) throw new Error(`找不到 ${pkg} 的入口: ${path}`)
	return import(pathToFileURL(path).href)
}

let evaluatePluginCompatibility
let getDshRuntimeVersion
let validateTypertManifest
try {
	;({ evaluatePluginCompatibility, getDshRuntimeVersion } = await loadLib('dsh-app-boot', 'index.js'))
} catch (error) {
	console.error(`✗ 闸一（peer 兼容）定位失败: ${error.message}`)
	console.error('  DSH 可能改了包结构——按 references/workflow.md 的「重新推导」步骤重新定位。')
	process.exit(2)
}
try {
	;({ validateTypertManifest } = await loadLib('dsh-typert-loader', 'index.js'))
} catch (error) {
	console.error(`✗ 闸二（typert 清单）定位失败: ${error.message}`)
	console.error('  DSH 可能改了包结构——按 references/workflow.md 的「重新推导」步骤重新定位。')
	process.exit(2)
}

const runtime = runtimeArg ?? getDshRuntimeVersion()
console.log(`dsh ${runtime}  |  ${DSH}\n`)

/** 复刻 loader 的 exports["./typert"] 解析：字符串，或带 default 字符串的对象。 */
function typertExportOf(manifest) {
	const exportsField = manifest.exports
	if (!exportsField || typeof exportsField !== 'object') return undefined
	const target = exportsField['./typert']
	if (typeof target === 'string') return target
	if (target && typeof target === 'object' && typeof target.default === 'string') return target.default
	return undefined
}

let clean = 0
let skipped = 0
let fatal = 0

for (const raw of dirs) {
	const dir = resolve(raw)
	let manifest
	try {
		manifest = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
	} catch (error) {
		console.log(`── ${dir}`)
		console.log(`   ✗ 读不到 package.json: ${error.message}\n`)
		fatal += 1
		continue
	}

	console.log(`── ${manifest.name ?? '(无名)'}@${manifest.version ?? '?'}  (${dir})`)

	// 闸一：peer 范围。不过 → 该 bundle 被跳过（安全，DSH 不崩）。
	let gate1Pass = true
	try {
		const issue = evaluatePluginCompatibility(manifest, {}, runtime)
		if (issue === undefined) {
			console.log('   闸一 peer      ✅ PASS')
		} else {
			gate1Pass = false
			console.log(`   闸一 peer      ❌ FAIL  不满足: ${JSON.stringify(issue.peers)}`)
			console.log('                  → 该 bundle 会被跳过：插件不生效，但 DSH 不会崩')
		}
	} catch (error) {
		gate1Pass = false
		console.log(`   闸一 peer      ❌ 无法判定: ${error.message}`)
	}

	// 闸二：typert 清单。不过 → 激活期抛错，可能崩掉整棵树。
	const rel = typertExportOf(manifest)
	let gate2Pass = true
	if (rel === undefined) {
		console.log('   闸二 typert    ∅  无 ./typert 清单（不经闸二）')
	} else {
		try {
			const module = await import(pathToFileURL(join(dir, rel)).href)
			validateTypertManifest(manifest.name, module.TYPERT)

			// 校验器只查结构；这里按网关的真实调用路径再走一遍 codec.create()。
			let codecs = 0
			for (const invocation of module.TYPERT.invocations ?? []) {
				const candidates = [
					...(invocation.parameters ?? []).map((parameter) => parameter.codec),
					invocation.result,
					invocation.invocation?.codec,
				].filter(Boolean)
				for (const codec of candidates) {
					if (codec.mode === 'src-json') continue
					if (typeof codec.create !== 'function') throw new Error(`invocation "${invocation.id}" 的 codec 没有 create() 工厂`)
					const schema = codec.create()
					if (!schema || typeof schema.parse !== 'function') throw new Error(`invocation "${invocation.id}" 的 create() 没有返回可 parse 的 schema`)
					codecs += 1
				}
			}
			console.log(`   闸二 typert    ✅ PASS  (${(module.TYPERT.invocations ?? []).length} 个 invocation，${codecs} 个 codec 可用)`)
		} catch (error) {
			gate2Pass = false
			console.log(`   闸二 typert    ❌ FAIL  ${error.message}`)
			console.log('                  → 致命：激活期在场会崩整棵树；稳态挂载则只记日志、静默失效')
		}
	}

	// 结论
	if (!gate2Pass) {
		fatal += 1
		console.log('   结论           ⛔ 致命')
	} else if (!gate1Pass) {
		skipped += 1
		console.log('   结论           ⚠️  会被跳过（安全）')
	} else {
		clean += 1
		console.log('   结论           ✅ 两闸都过')
	}
	console.log('')
}

console.log(`合计: ${clean} 通过 · ${skipped} 会被跳过(安全) · ${fatal} 致命`)
process.exit(fatal > 0 ? 1 : 0)
