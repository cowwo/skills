---
name: dsh-plugin-publish
description: 发布一个 DSH 插件：把本地代码提交到 GitHub，用一个 tag 触发 GitHub Actions，自动把插件同时发成两个 npm 包（裸名 + 带 scope 前缀）并创建一个 GitHub Release 版本页。通用版——包名、GitHub 仓库、分支、scope 都从当前本地仓库读取，不写死某个具体插件。当用户说「发布/打包/上传插件到 npm 或 GitHub」「发新版本」「打个 tag 发一下」时使用。
---

# DSH 插件发布流程（通用版）

发布 = 把本地改动推上 GitHub + 打一个版本标签。其余（npm 打包、GitHub Release）由 GitHub Actions 自动完成。你只负责提交和打标签，不要手动操作 npm 网页。

## 总原则：不确定就问，绝不猜

发布是一次性动作（npm 版本发出去收不回），本流程对「不确定」零容忍。凡属下列任一情况，**停下来问用户**，用户确认前不执行任何写操作（commit / push / tag / npm 命令）：

- **读不到或读出多个候选**：某个变量（包名、scope、仓库、分支、版本）读不出来，或存在两种以上解释（比如 npm 组织名和 GitHub owner 不一致、有多个 remote、目录里有多个 `package.json`）。
- **对不上**：现场读到的值和用户说的、或和预期对不上（tag 与版本号不一致、认证账号不是预期账号、远端已有同名 tag）。
- **命令行为异常**：报错、输出为空、输出和本文件描述的不一样（比如 `npm version` 没改 lockfile、`git push` 被拒）。
- **没见过的事实**：本文件覆盖不到的角落（workflow 内部行为、NPM_TOKEN 是否还有效、scope 归属）——宁可问，别替仓库/机器人代言。
- **要做取舍**：同一目标有多条路（升版本 vs 删 tag、跳过某步 vs 继续、回滚 vs 前进），选择权在用户。

问的时候把「我看到了什么 + 我拿不准什么 + 我建议怎么办」一次说清，让用户能一句拍板。**宁可多问一句，不可错发一版。**

## 先确定这几项（不要写死）

在插件目录里，用命令把下面的值读出来当作变量用；读不到的值再问用户。**不要照抄旧值**——每次都要按当前仓库重新读。

| 变量 | 怎么读 |
| --- | --- |
| **裸名包名** `BARE` | `node -p "require('./package.json').name"`。若结果带 `@scope/`，把 `scope` 挪到下一行 |
| **scope / 前缀** `SCOPE` | 若 `package.json` 名字已是 `@scope/name`，直接取 `scope`；否则默认取 GitHub 仓库 owner（git remote 的 org），并跟用户确认一次 |
| **GitHub 仓库** `OWNER/REPO` | `gh repo view --json nameWithOwner --jq .nameWithOwner`（gh 用的是 origin 那个仓库）；没有 gh 就从 `git remote get-url origin` 解析出 `owner/repo`（去掉协议、主机名和结尾 `.git`） |
| **分支** `BRANCH` | `git branch --show-current`（空则默认 `main`） |
| **推送账号** | 见下方「推送账号确认」，确认无误才许推 |
| **发布钥匙** `NPM_TOKEN` | GitHub 的 secret，不用问、不用动 |

### 推送账号确认（每次推送前必做）

推送用的账号有两层，都要先亮给用户确认，**用户点头之前一条 push 都不许发**：

1. **远程归属**（代码推给谁）：`git remote get-url origin` 读出来给用户看，确认这就是要发布的仓库（owner/repo 对得上第 0 步读的 `OWNER/REPO`）。
2. **提交身份**（commit 挂谁名下）：在插件目录跑
   ```bash
   git config user.name; git config user.email
   ```
   把结果亮给用户。**两项有任一为空就是没配置**：git 会静默用系统用户名和一个 `用户名@主机名` 的假邮箱，推上去不关联任何 GitHub 账号。此时停下来，让用户自己给出 `user.name` / `user.email` 并在**仓库内**（不加 `--global`）配好，或让用户改用他惯用的机器——**不要替用户编造身份**。
3. **权限归属**（谁有权推）：`ssh -T git@github.com` 成功会回显 `Hi <用户名>! You've successfully authenticated`。把回显的用户名亮给用户，确认这就是预期账号。HTTPS 远程就跳过这条。

> 把三项汇成一句报给用户，例如：「本次推送 → 仓库 `cowwo/dsh-provider-info`，提交身份 `张三 <zhangsan@xx.com>`，认证账号 `cowwo`，确认推送吗？」
> 以后每次发布都重新走这三步。机器换过人、SSH key 换过绑，只有现场核对才拦得住。

下面这几样**仓库里读不到，必须问用户**，缺了就问，别自己编：

| 用户提供 | 干什么用 |
| --- | --- |
| **目标版本号** `VERSION` | 第 2、3、4 步的 `<目标版本>` 都用它，例如 `0.1.5` |
| **这次的改动说明** | 写成第 1 步的 commit message |

拿到 `VERSION` 后先做三个检查，过了再往下跑：

1. **去掉开头的 `v`**：用户说 `v0.1.5` 就当 `0.1.5` 用（tag 里的 `v` 由第 3 步自己加，不处理就会打出 `vv0.1.5`）。
2. **必须比当前版本高**：先读 `node -p "require('./package.json').version"`，目标 ≤ 当前就停下来跟用户确认。npm 本地**不会**拦住重复/降版本，等到 Actions 里才失败，白跑一轮。
3. **远端查重（两个包都要查）**：`npm view "$BARE@<目标版本>" version` 和 `npm view "@$SCOPE/$BARE@<目标版本>" version` 各跑一次，**任一条**查得到版本号就说明该版本已被占用（可能是历史半发布留下的错位），停下来换版本。查不到包或网络不通就跳过这条，靠第 2 条兜底。

> Release 页面的说明内容由 workflow 默认生成（一般是安装命令），这里不用收集。

发布时要发成的两个包名：

- **裸名**：`BARE`（形如 `dsh-provider-info`）
- **scoped 名**：`SCOPE` 非空时 = `@SCOPE/BARE`；若 `BARE` 本身已带 `@.../`，则 scoped 名就是 `BARE`，裸名 = 去掉 `@SCOPE/` 后剩下的部分

> 注意：仓库里 `package.json` 的 `name` **只保留裸名**（不带 scope）。scoped 名是发布时临时加的前缀，不写回仓库。

## 两个 npm 包的规则（它们是两个独立包）

npm 眼里，`BARE` 和 `@SCOPE/BARE` 是**两个互不相干的包**：各有各的版本历史，互不知道对方存在。本流程靠「同一次 Actions、先后各发一次、同一版本号」把它们绑在一起（实测顺序：先发裸名，约 2 秒后再发 scoped）。由此推出几条必须遵守的规则：

- **版本同步是约定，不是 npm 保障**。npm 不会替你对齐两个包；只要有一次「一边成功、一边失败」，两边版本就**永久错位**。真实教训：`dsh-provider-info` 至今缺 0.1.0——最早那次只发成了 scoped 一边，裸名那边没上去，这个洞补不回来（同版本号不能重发），只能往前走。
- **重发判断要两个包一起查**：**任一**包已占用目标版本，就算重发，必须升版本（见上面检查 3）。
- **可能「半发布」**：一边成功、一边失败。常见原因：裸名被别人抢注（403）、token 没有 scope 权限（403）、scoped 包缺 `--access public`（402）、版本已占用（EPUBLISHCONFLICT）。处理：修好原因 → **升版本重发**；已发出去的那半不能覆盖，也不要删。
- **裸名先到先得，scoped 名防抢注**：`BARE` 是全局唯一的公共名字，被别人注册过就永远发不了；`@SCOPE/BARE` 只要 token 的账号拥有这个 scope 就一定发得上去。这就是双发的意义：裸名好装好记，scoped 名保住命名空间。
- **收尾动作要两边各来一次**：`unpublish` / `deprecate` 要对两个包**分别**执行，只动一边，另一边还挂在 npm 上。

**前置条件（缺了会白跑）：** 仓库里必须**已有**那个 GitHub Actions workflow，它负责「发裸名包 + 发 scoped 包 + 建 GitHub Release」。如果仓库里根本没有这个 workflow，发布不会发生——这一步先确认，再往下走。

## 发布步骤

### 1. 提交本地改动到 GitHub
```bash
git status --short
git add -A
git commit -m "<这次的改动说明>"
git push origin "$BRANCH"
```
> 先看 `git status --short`：输出为空（本地没改动）就**跳过本步**直接进第 2 步，免得 `git commit` 报「nothing to commit」卡住。push 被拒（远端有新提交）就先 `git pull --rebase` 再推。
完成标准：`git push` 成功（或本步被跳过），工作区干净。

### 2. 升版本号（用 npm 命令，别手改两处）
```bash
npm version <目标版本> --no-git-tag-version
git add package.json package-lock.json
git commit -m "chore: 版本号升到 <目标版本>"
git push origin "$BRANCH"
```
> 用 `npm version <目标版本> --no-git-tag-version` 会自动把 `package.json`、`package-lock.json` 的顶层 `version` 和 `packages[""].version` 一起升到一致，且**不会**自动打 tag（tag 留给第 3 步）。上一版「手动改开头两处」容易漏改 lockfile 里的 `packages[""].version`，改用这个命令更稳。
完成标准：`node -p "require('./package.json').version"` 等于目标版本，已推送。

### 3. 打 tag 并推送（触发自动发布）
tag 名 = `v<目标版本>`（例如 `v0.1.5`）。
```bash
git tag -a "v<目标版本>" -m "release v<目标版本>"
git push origin "v<目标版本>"
```
> 用 annotated tag（`-a -m`）。打 tag 前先确认第 2 步的版本号确实等于目标版本，避免 tag 和版本对不上。commit 已推送、工作区干净再打 tag。
完成标准：tag 推送成功。这会触发 GitHub Actions。

### 4. 等自动发布并验证
GitHub Actions 会自动：发裸名包、发 scoped 包、建 GitHub Release。**先确认机器人真被叫醒了**，再验结果：
```bash
gh run list -R "$OWNER/$REPO" --limit 3
```
> 看有没有一条由刚才那个 tag 触发的新 run。**一条新 run 都没出现，说明仓库里根本没有那个 workflow**（前置条件不成立）——停下来补 workflow，别干等。

等 run 跑成 success（一般一两分钟），再验证发布结果：
```bash
npm view "$BARE@<目标版本>" version
npm view "@$SCOPE/$BARE@<目标版本>" version
gh release view "v<目标版本>" -R "$OWNER/$REPO"
```
（若无 scope，就只查裸名那一行。）
完成标准：两条 `npm view` 都回显目标版本，且 GitHub Release 名字 = `v<目标版本>`（正好一个 `v`）。

## 注意事项（踩过的坑）

- **不确定就停**：读不到、对不上、没见过、要取舍——任何一样拿不准，先问用户再动（见开头「总原则」）。问一句的成本，远低于错发一版。
- **版本不能重发**：两个包同一个版本发过一次，再发必须升版本，否则失败。
- **tag 已存在 = 这版本发过了**：`git tag` 报 already exists，说明该版本已发布（或发布过一半）。直接换更高的版本号重来，**别删 tag 重推**（npm 那边已经占了这个号）。
- **npm 发出去的版本收不回**：同一个版本号不能覆盖重发。发布后 72 小时内、且没有别的包依赖时可以 `npm unpublish`；过了就只能 `npm deprecate` 标记废弃。
- **tag 跟版本号对应**：版本 0.1.5 → tag `v0.1.5`。
- **Release 名别多写一个 v**：写 `v0.1.5`，写成 `vv0.1.5` 是错的。
- **发布钥匙 7 天过期**：`NPM_TOKEN` 到期要换，别泄露。
- **仓库里包名永远是裸名**：scoped 名是发布时临时加的，不写回仓库。
- **推送前必须核对账号**：远程归属、`git config user.name/email`、SSH 认证用户名三项都要用户确认后才推送。身份没配就推送，会产生不关联账号的「幽灵提交」（假邮箱 `用户名@主机名`），GitHub 上头像/贡献全丢。
- **Actions 失败先查这三样**：`NPM_TOKEN` 是否过期、该版本是否已发布过、workflow 语法是否正确。发布失败基本就是这几类。
