---
name: model-fingerprint
description: 用官方 CLI（lmfpd）对某个 API 端点做「随机整数指纹」检测，判定背后模型。文档 https://lm.ikale.io/docs/cli/detect/ ；默认一口气跑完并给结论。
whenToUse: 用户想确认某个模型/中转端点是否为宣称版本（如 deepseek-v4.1-flash 是否 1017）、怀疑降智或换模型，或直接说"用 CLI 测一下这个模型"。
user-invocable: true
---

# 模型指纹检测 · CLI 模式

官方文档：<https://lm.ikale.io/docs/cli/detect/>
原理：让模型凭第一反应写 300 个左右的 1–355 整数，模型对数值/区间/末位的偏好就是指纹，与参考库（60 个模型）比对得出候选。

CLI 与网页共用同一份检测器和参考库；区别只是请求从终端发出、打分在本地完成。

## 铁律

- **一口气跑完**：不要逐条让用户确认，采完、算完、再汇报。
- **只信命令输出**：结论必须来自 CLI 的排名和置信度，不得自己推测或编造。
- **失败照实说**：退出码非 0、样本失败、置信度不足都要原样报告，不许粉饰。
- **不自动重试掩盖问题**：CLI 本身不重试；遇到 429/余额不足这类错误，先报告原因，再询问是否重试。

## 第 0 步：确定目标

需要三样：**Base URL**、**API Key**、**模型名**。

- 用户直接给了 → 直接用。
- 用户在 DSH 里已经配过 → 从 DSH 凭据库按引用名取，例如 `WB_ML_API_KEY`、`OPENCODE_GO_API_KEY`、`CMD_01_API_KEY`；端点取对应 provider 的 `baseURL`。
- 从 `~/.dsh/.credentials.yaml` 的 `refs` 段读取，**不要打印明文**：

```bash
KEY=$(python3 -c "import yaml;print(yaml.safe_load(open('$HOME/.dsh/.credentials.yaml'))['refs']['WB_ML_API_KEY'])")
```

- 用户点名的模型和实际要请求的端点不一致时，停下来确认一次。

## 第 1 步：跑检测

### 标准命令（推荐：走包装脚本）

Key 不进 argv，包装脚本在运行时从凭据库读取并经 `API_KEY` 环境变量传给 CLI：

```bash
.dsh/skills/model-fingerprint/scripts/fpd-run.sh <凭据引用> <BASE_URL> <MODEL> \
  -a chatcompletion --count 3 --parallel 3
```

例：

```bash
.dsh/skills/model-fingerprint/scripts/fpd-run.sh \
  WB_ML_API_KEY http://127.0.0.1:9001/v1 deepseek-v4.1-flash --count 3
```

脚本行为：

- 从 `~/.dsh/.credentials.yaml` 的 `refs` 段按名字取 Key，读不到就报错退出；
- `export API_KEY=...` 后 `exec`，Key 不落命令行、不进 shell history；
- 自动加 `--no-update-check`，默认 `--output /tmp/fpd-<凭据引用>.json`；
- `--dry-run` 只打印将执行的命令，Key 显示为 `sk-***`。

### 兜底命令（不用脚本时）

```bash
KEY=$(python3 -c "import yaml;print(yaml.safe_load(open('$HOME/.dsh/.credentials.yaml'))['refs']['WB_ML_API_KEY'])")
API_KEY="$KEY" bunx lmfpd@latest -b <BASE_URL> -m <MODEL> -a cc --count 3 --no-update-check
```

**不要**写成 `-k "$KEY"`：展开后 Key 会出现在进程命令行里。

- `npx lmfpd@latest` 等价；本机有 bun 时 `bunx` 更快。
- `-a`：OpenAI 兼容用 `chatcompletion`（或 `cc`）；`/v1/messages` 用 `message`；官方/Responses 端点用默认的 `responses`。
- `-b` 只写主机名时自动补 `/v1`；带路径则保留路径再追加端点。
- 默认已是 SSE、宽松模式、3 样本、3 并发、1 轮，显式写上便于复现。

### 命令超时

单次检测通常 1–4 分钟（本地代理端点可能更慢）。用后台任务跑，别让前台命令超时：

```bash
bunx lmfpd@latest ... > /tmp/fpd.log 2>&1
```

或交给宿主的长任务机制。

### 常用变体

```bash
# 多轮复测（5 轮）
... -n 5

# 严格模式：要求三条完整有效回答，不允许自动截断
... -s

# 少发请求：每轮 1 条（只给排名，没有置信度）
... --count 1

# 关闭流式
... -ns --timeout 180

# 附带分词器探测（约多发 12 个请求，按请求计费的接口会额外花钱）
... --tokenizer

# 机器可读输出
... --json
```

## 第 2 步：读结果

终端里关键区块：

```
LEADING CANDIDATES
 #   Model                       Score  Confidence
 1   deepseek-v4.1-flash-1017    2.823       98.8%
 2   deepseek-v4.1-flash         1.854        0.9%
```

判定规则：

| 情况 | 结论 |
|---|---|
| 三条样本有效、校准匹配 | **Calibrated ranking**，可报置信度 |
| 只有 1–2 条有效 | 只报排名，**不要报置信度** |
| 校准不匹配 | **Uncalibrated ranking**，置信度不可用 |
| 前两名相差 < 15 个百分点 | 判「库内无法区分」，建议换题/多轮重测 |
| 标记 `Not a model reply` | 数字不像模型产出，重采 |
| 某样本提示分布异常 | 该轮结果不可靠，换题重测 |

置信度 = **参考库 60 个模型之间的相对概率**，不是"真货概率"；命中同名只是支持证据，不能单独证明身份；库外模型识别不了，会归到最近候选。

## 第 3 步：离线复算（可选）

已有报告时不需要再请求模型：

```bash
bunx lmfpd@latest --input /tmp/fpd-<名字>.json --json
```

也接受纯文本数组：`[{"text":"...","expected_count":323}, ...]`。

## 第 4 步：汇报模板

```
被测端点：<Base URL>
被测模型：<MODEL>
判定：<第一名>
置信度：98.8%（库内相对概率）
次选：<第二名> 0.9%
样本：323/323、328/328、304/304，3/3 有效
耗时：<秒>
报告：/tmp/fpd-<名字>.json
```

不可判定时写清楚：前两名分别是谁、相差多少、建议怎么重测。

## 故障处理

| 现象 | 含义 | 处理 |
|---|---|---|
| 退出码 0 | 所有轮次都给出排名 | 正常 |
| 退出码 1 | 输入无效或有轮次未评分 | 看日志，定位具体样本失败原因 |
| 退出码 130 / 143 | 用户取消 / SIGTERM | 报告已保存的样本 |
| `401` / `403` | Key 不对、缺 header、被 Cloudflare 拦 | 核对凭据，注意有的网关要求额外 session 头，CLI 无法自定义 header，需自建转发代理 |
| `429` | 上游限流 | 报告冷却时间，等够再跑；可把 `--parallel` 降到 1 |
| `400 insufficient credits` | 账户欠费 | 直接报告，不要换模型硬试 |
| 模型返回空 | 推理吃满输出预算 | 该样本重采；或换更短的目标数 |
| `bunx`/网络不可用 | 无法下载 CLI | 改用网页手动模式 |

## 凭据安全

- Key 只经环境变量传入（`API_KEY`），**不要用 `-k` 把明文放进命令行**，也不要 echo 或写进报告。
- `--output` 的报告经实测不含凭据，可以安全保留。
- 不要把 Key 发到 lm.ikale.io：CLI 的判断全在本地，不联网到该站点。
- CLI 唯一无关外联是更新检查（npm 三个镜像，只 GET 版本号，不带凭据）；`--no-update-check` 可彻底关掉。
- 磁盘层面：凭据文件是明文、权限 0600。若 FileVault 未开启，建议开启。
