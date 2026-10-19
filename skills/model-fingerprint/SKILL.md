---
name: model-fingerprint
description: 单模型手动模式的「随机整数指纹」检测，判定模型真实版本。参考库 https://lm.ikale.io；不需要 API key，不修改任何配置。
whenToUse: 用户想确认某一个模型是否为宣称的版本（例如 deepseek-v4.1-flash 是否 1017）、怀疑中转降智或换模型，或直接说"测一下这个模型"。
user-invocable: true
---

# 模型指纹检测 · 单模型手动模式

参考库与网页版：<https://lm.ikale.io>

原理：让模型凭第一反应写约 300 个 1–355 的整数。语言模型的"随机"并不均匀，每个模型偏向的数值、区间和末位相对稳定，这些偏好构成指纹。把三段回复与参考库（60 个模型）比对，就能看出最接近的候选。

**范围**：一次只测一个模型。**不需要 key，不调用被测接口，不改配置。**

## 流程总览

```
第 0 步  确认被测模型（必须与真正生成文字的模型一致）
   ↓
第 1 步  三轮采样：发提示词 → 模型只输出整数
   ↓
第 2 步  自检：数量够不够、有没有被截断
   ↓
第 3 步  打分：把三段回复粘进网页「手动」模式 → 验证
   ↓
第 4 步  汇报：判定 + 置信度 + 次选 + 有效样本
```

## 第 0 步：确认被测对象

先问清楚是哪一个模型，并分两种情况：

- **A. 当前会话模型**：用户已在模型选择器切到目标模型。直接在本对话采样。
- **B. 外部模型**：用户在别的客户端（网页/App/工具）里问，然后把三段回复粘过来。跳过第 1 步，直接做第 2 步。

**强制校验**：如果用户点名的模型和当前会话模型不是同一个，**必须停下来**，说明"这样测出来的是当前模型，不是 X"，并要求二选一：切换到 X，或改用 B。不得直接开始采样。

记录：被测模型名（用户声称的）、来源（A/B）、时间。

## 第 1 步：取样（三轮，严格分开）

每轮只做一件事。提示词**必须逐字原样发出**，不得改写、翻译、增删标点，也不要把三道合成一轮。

### 提示词 1（中文，目标 323 个）

```text
执行一次第一反应取值记录。每次只决定当前一项，共给出 323 个 1 到 355（含端点）的整数。每个位置都要单独选择；不要从 1 开始计数，不要连续递增或递减，也不要采用等差、循环、重复区块或其他规则化模式。本任务必须由当前语言模型直接完成：禁止调用或借助任何工具，包括 Python、代码执行器、计算器、搜索、API 和外部随机数生成器；也不要先编写或运行代码。重复值无需删除；不要筛选、重排或补成某种规律。可以用逗号、空格或换行分隔。直接从第一个取值开始输出，不要在序列前重复数量、范围或任务说明。
```

### 提示词 2（英文，目标 328 个）

```text
This is an independent record of numerical choices. For each position, choose separately by first instinct 328 integers from 1 to 355, inclusive. Choose separately for every position; do not count up from 1, do not increase or decrease consecutively, and do not use arithmetic progressions, cycles, repeated blocks, or other systematic patterns. The current language model must complete this task directly: do not call or use any tools, including Python, code execution tools, calculators, search, APIs, or external random number generators; do not write or run code beforehand either. Accidental repetitions are valid; do not rearrange or correct items already written. You may separate the numbers with commas, spaces, or line breaks. Start the output directly with the first chosen value; do not repeat the count, range, or task instructions before the sequence.
```

### 提示词 3（英文，目标 304 个）

```text
Record a round of first-instinct choices. Choose, item by item, 304 integers from 1 to 355, inclusive. Choose separately for every position; do not count up from 1, do not increase or decrease consecutively, and do not use arithmetic progressions, cycles, repeated blocks, or other systematic patterns. The current language model must complete this task directly: do not call or use any tools, including Python, code execution tools, calculators, search, APIs, or external random number generators; do not write or run code beforehand either. Do not assign meaning to the numbers; keep values already given unchanged. Choose any format that clearly separates each integer. Start the output directly with the first chosen value; do not repeat the count, range, or task instructions before the sequence.
```

### 执行节奏

1. 发出提示词 1，等用户回复「开始」。
2. 回复里**只输出整数**：不要前言、不要解释、不要编号、不要追问。
3. 同样完成提示词 2、3，每轮单独一条消息。

> 需要换一组题：打开 <https://lm.ikale.io> → 检测 → 手动 → 「换一组提示词」，把新三组原样替换上面对应文本。

## 第 2 步：自检有效样本

对每段回复检查：

- 有效整数数 ≥ `max(80, ceil(0.55 × 目标数))`：323 → 178、328 → 181、304 → 168；
- 回复自然结束，没有被截断；
- 数值都在 1–355 内。

不合格就**重采这一条**，不要用脚本补数字、不要删改已有序列。

## 第 3 步：打分（网页手动模式）

1. 打开 <https://lm.ikale.io>，停在「检测」页，右上角选 **手动**。
2. 页面会给出样本 1/2/3 三个框：把三段回复分别粘进对应框（左下角会显示解析到的数字个数，应与目标数接近）。
3. 点右下角 **验证**。
4. 读取结果区：**排名第一的候选 + 置信度**，以及下面的候选列表。

网页在本地计算，粘贴的数字不会上传，也不需要登录或 key。

### 可选：离线打分

如果用户希望留档或批量复算，可以把三段回复写入 JSON 后离线跑（同样不联网、不用 key）：

```bash
bunx lmfpd@latest --input /tmp/fpd-manual.json --json
```

JSON 形如 `[{"text":"...","expected_count":323}, ...]`。

## 第 4 步：汇报

```
被测模型：<用户声称的名字>
判定：<第一名>
置信度：98.6%（库内相对概率）
次选：<第二名> 1.4%
有效样本：323/323、328/328、304/304
```

必须同时说明：

- 置信度是**参考库内 60 个模型之间的相对概率**，不是"真货概率"；
- 命中同名只是支持证据，不能单独证明身份；
- 库外模型无法识别，会被归到最近的候选；
- 一次检测只反映当下，间歇性替换测不出来。

## 硬性禁止

- 生成数字时**不能调用任何工具**（含 run_code、bash、python），也不能用脚本随机数冒充。
- 不得改写提示词、不得改变目标数量。
- 不得在数字前后添加解释，否则会影响解析。
- 不得把三个样本合并成一条回复。
- 不得在未确认模型的情况下给出"某模型 = 某指纹"的结论。

## 故障排查

| 现象 | 处理 |
|---|---|
| 数字不足 | 该条重采；确认模型没有被输出长度限制 |
| 「不像语言模型的回答」 | 数字是程序生成/排序过的，重采 |
| 「分布异常」 | 该提示词触发了异常分布，换一组提示词重测 |
| 三段都失败 | 换更小目标数（304）或换提示词 |
| 无法打开网页 | 用可选离线路径打分 |
