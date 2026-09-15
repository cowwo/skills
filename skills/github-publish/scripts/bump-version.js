#!/usr/bin/env node
// 把 package.json / package-lock.json 的版本号改到目标版本。
//
// 设计原则：只替换 version 的【值本身】，绝不重新格式化文件。
//   - 保持原缩进（2 空格 / 4 空格 / tab）和结尾换行原样
//   - 不碰依赖条目的 version（package-lock.json 的 packages["node_modules/*"] 一律不动）
//   - 只用 node 标准库，不依赖 npm
//
// 用法: node bump-version.js <目标版本，不带 v>
//   例: node bump-version.js 0.2.0
//
// 退出码: 0 成功（含"文件不存在，跳过"）/ 1 出错（未写入任何文件）/ 2 用法错误

const fs = require("fs");

const v = process.argv[2];
if (!v || v === "-h" || v === "--help") {
  console.error("用法: node bump-version.js <目标版本>   例: node bump-version.js 0.2.0");
  process.exit(2);
}
if (/^v/i.test(v)) {
  console.error("目标版本带了 v 前缀: " + v + " —— 先剥掉 v 再传（tag 上的 v 由发布流程自己加）。");
  process.exit(2);
}

// 扫出文本里所有字符串字面量，记录它的起始下标、所在对象的嵌套深度、以及它是不是一个 key。
function strings(text) {
  const out = [];
  let depth = 0, inStr = false, esc = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === "{") { depth++; continue; }
    if (c === "}") { depth--; continue; }
    if (c !== '"') continue;
    let j = i + 1, f = false;
    for (; j < text.length; j++) {
      const x = text[j];
      if (f) { f = false; continue; }
      if (x === "\\") { f = true; continue; }
      if (x === '"') break;
    }
    const isKey = /^\s*:/.test(text.slice(j + 1));
    out.push({ i: i, d: depth, isKey: isKey, k: isKey ? JSON.parse(text.slice(i, j + 1)) : null });
    i = j;
  }
  return out;
}

// 给定一个 key 的下标，返回它后面那个字符串值的 [起, 止) 下标。
function valueRange(text, keyIdx) {
  const colon = text.indexOf(":", keyIdx);
  const q = text.indexOf('"', colon);
  let j = q + 1, f = false;
  for (; j < text.length; j++) {
    const x = text[j];
    if (f) { f = false; continue; }
    if (x === "\\") { f = true; continue; }
    if (x === '"') break;
  }
  return [q, j + 1];
}

// 挑出这次要改哪几个 version：顶层那个，外加 lockfile 里 packages[""] 那个。
function plan(text, file) {
  const ks = strings(text);
  const targets = [];
  const top = ks.find((x) => x.isKey && x.k === "version" && x.d === 1);
  if (top) targets.push(top.i);
  if (file === "package-lock.json") {
    const pi = ks.findIndex((x) => x.isKey && x.k === "packages" && x.d === 1);
    if (pi >= 0) {
      const ei = ks.findIndex((x, n) => n > pi && x.isKey && x.k === "" && x.d === 2);
      if (ei >= 0) {
        const vi = ks.findIndex((x, n) => n > ei && x.isKey && x.k === "version" && x.d === 3);
        if (vi >= 0) targets.push(ks[vi].i);
      }
    }
  }
  return targets;
}

function bump(file) {
  if (!fs.existsSync(file)) {
    console.log(file + ": 跳过（文件不存在）");
    return;
  }
  let text = fs.readFileSync(file, "utf8");
  const before = JSON.parse(text).version;
  const targets = plan(text, file).sort((a, b) => b - a);
  if (targets.length === 0) {
    throw new Error(file + " 里找不到顶层 version 字段——文件结构不符合预期，请让用户确认版本号该改哪里");
  }
  for (const i of targets) {
    const r = valueRange(text, i);
    text = text.slice(0, r[0]) + JSON.stringify(v) + text.slice(r[1]);
  }
  // 自检：改完重新解析，全部对上了才允许写盘。
  const after = JSON.parse(text);
  if (after.version !== v) {
    throw new Error(file + " 自检没过（顶层 version 不是 " + v + "），未写入");
  }
  if (file === "package-lock.json" && after.packages && after.packages[""] && after.packages[""].version !== v) {
    throw new Error(file + ' 自检没过（packages[""].version 不是 ' + v + "），未写入");
  }
  fs.writeFileSync(file, text);
  console.log(file + ": " + before + " -> " + v);
}

for (const f of ["package.json", "package-lock.json"]) {
  try {
    bump(f);
  } catch (e) {
    console.error("失败: " + e.message);
    process.exit(1);
  }
}
