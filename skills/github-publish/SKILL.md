---
name: github-publish
description: 发布一个 GitHub 仓库的新版本：把本地改动提交推送、把版本号升到目标版本、打 annotated tag 推上去，然后产出 GitHub Release 版本页——先探测仓库里有没有 release workflow，有就靠它自动建，没有就用 gh CLI 兜底。全程不发布 npm。仓库、分支、版本、版本载体都从当前本地仓库现场读取，不写死。当用户说「发布到 GitHub」「发个 release / 版本页」「打个 tag 发一下」「推上去发新版」时使用。
---

# GitHub 发布流程（通用版，不含 npm）

发布 = 把本地改动推上 GitHub + 升版本 + 打一个版本 tag + 产出一个 Release 版本页。

**本流程不发 npm**：不跑 `npm publish`、不碰 npm 网页、不需要 `NPM_TOKEN`，也不往仓库里塞发布用的 workflow。升版本用本 skill 自带的 `scripts/bump-version.js` 直接改文件，不借 `npm version` 的手（它既会悄悄改 lockfile，也会顺手替你打 tag）。

## 总原则：不确定就问，绝不猜

发布是一次性动作（tag 和 Release 推出去就是公开记录，改不回去），本流程对「不确定」零容忍。凡属下列任一情况，**停下来问用户**，用户确认前不执行任何写操作（commit / push / tag / gh release / 手动触发 workflow）：

- **读不到或读出多个候选**：某个变量（仓库、分支、版本、版本载体）读不出来，或存在两种以上解释（有多个 remote、目录里有多个 `package.json`、版本文件不止一个、monorepo）。
- **对不上**：现场读到的值和用户说的、或和预期对不上（tag 与版本号不一致、认证账号不是预期账号、远端已有同名 tag、目标版本 ≤ 当前版本）。
- **命令行为异常**：报错、输出为空、输出和本文件描述的不一样（比如升版本后 `git diff` 里混进大量无关改动、`git push` 被拒）。
- **没见过的事实**：本文件覆盖不到的角落（仓库里那个 release workflow 到底干什么、分支保护规则、仓库是否私有、是否开了 immutable release）——宁可问，别替仓库代言。
- **要做取舍**：同一目标有多条路（升版本 vs 删 tag、跳过某步 vs 继续、草稿 vs 直接发布、回滚 vs 前进），选择权在用户。

问的时候把「我看到了什么 + 我拿不准什么 + 我建议怎么办」一次说清，让用户能一句拍板。**宁可多问一句，不可错发一版。**

## 先确定这几项（不要写死）

在仓库目录里用命令把下面的值读出来当变量用；读不到的值再问用户。**不要照抄旧值**——每次都要按当前仓库重新读。

| 变量 | 怎么读 |
| --- | --- |
| **GitHub 仓库** `OWNER/REPO` | `gh repo view --json nameWithOwner --jq .nameWithOwner`（gh 用的是 origin 那个仓库）；没有 gh 就从 `git remote get-url origin` 解析出 `owner/repo`（去掉协议、主机名和结尾 `.git`） |
| **分支** `BRANCH` | `git branch --show-current`；为空（detached HEAD）就用 `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` |
| **是否私有** | `gh repo view --json isPrivate --jq .isPrivate`（影响权限判断和 Release 可见性，报给用户） |
| **当前版本** `CUR` | 有 `package.json` → `node -p "require('./package.json').version"`；没有 → 最近一个 tag：`git tag --sort=-v:refname \| head -1`；两者都没有 = 首次发布 |
| **发布方式** | 见下方「第 0 步：探测有没有 release workflow」，方式 A 或方式 B |
| **推送账号** | 见下方「推送账号确认」，确认无误才许推 |

下面这几样**仓库里读不到，必须问用户**，缺了就问，别自己编：

| 用户提供 | 干什么用 |
| --- | --- |
| **目标版本号** `VERSION` | 第 2、3、4 步都用它，例如 `0.2.0` 或 `v0.2.0` |
| **这次的改动说明** | 写成第 1 步的 commit message |
| **Release 说明**（可选） | 默认用 `--generate-notes` 让 GitHub 自己按提交生成；用户给了就换成他的原文或 `--notes-file` |
| **要不要上传产物** | 有就 `gh release create` 后面跟文件/通配符，没有就不加 |

### 推送账号确认（每次推送前必做）

推送和建 Release 用的是两层账号，**用户点头之前一条 push、一条 `gh release` 都不许发**：

1. **远程归属**（代码推给谁）：`git remote get-url origin` 读出来给用户看，确认这就是要发布的仓库，owner/repo 对得上上面读到的 `OWNER/REPO`。
2. **提交身份**（commit 挂谁名下）：在仓库里跑
   ```bash
   git config user.name; git config user.email
   ```
   把结果亮给用户。**两项有任一为空就是没配置**：git 会静默用系统用户名和一个 `用户名@主机名` 的假邮箱，推上去不关联任何 GitHub 账号。此时停下来，让用户自己给出 `user.name` / `user.email` 并在**仓库内**（不加 `--global`）配好——**不要替用户编造身份**。
3. **发布身份**（谁有权建 tag / Release）：`gh auth status` 看当前登录账号；`gh api user --jq .login` 拿到用户名。**登录账号和 `OWNER` 不一致时要当场说明**：仓库属于组织、或发布者只是协作者时通常没问题，但个人仓库推别人的号一定 403——拿不准就问用户，不要试着硬推。
   - HTTPS 远程：`gh auth status` 结果就够了（gh 的凭据同时管 `git push`）。
   - SSH 远程：再跑一次 `ssh -T git@github.com`，成功会回显 `Hi <用户名>! You've successfully authenticated`，把这个用户名也亮出来。

> 把三项汇成一句报给用户，例如：「本次发布 → 仓库 `cowwo/skills`（公开），分支 `main`，提交身份 `cowwo <x@y.com>`，gh 登录账号 `cowwo`，准备发 `v0.2.0`，确认吗？」

### `VERSION` 的三项检查（过了再往下跑）

1. **去掉开头的 `v`**：用户说 `v0.2.0` 就当 `0.2.0` 用（tag 里的 `v` 由第 3 步自己加，不处理就会打出 `vv0.2.0`）。
2. **必须比当前版本高**：拿上面读到的 `CUR` 比，目标 ≤ 当前就停下来跟用户确认（`CUR` 读不到 = 首次发布，跳过这条）。
3. **远端查重**：
   ```bash
   git ls-remote --tags origin "refs/tags/v<VERSION>"
   ```
   **有输出 = 这个 tag 已经存在**，说明该版本已经发布过（或发布到一半），停下来换版本，别删 tag 重推。
   > 输出为空 = 远端没有这个 tag；但如果这个仓库**一个 tag 都没有**，输出同样为空——分不清时补一句 `git ls-remote --tags origin | head`，确认是「没有这个 tag」还是「整个仓库没 tag」。

## 第 0 步：探测有没有 release workflow（决定走 A 还是 B）

**这一步必须在打 tag 之前做完**：仓库里若已有 tag 触发的 release workflow，你再手动建一次 Release 会撞车（422 already exists）。

```bash
ls .github/workflows/*.y*ml 2>/dev/null
```

没有 workflow 文件 → **方式 B**（gh CLI 兜底），到此为止。

有 workflow 文件，就逐项看两件事：

```bash
# (a) 触发条件是不是 tag / release
grep -nE "^\s*(on:|push:|release:|tags:|branches:)" .github/workflows/*.y*ml
# (b) 里面有没有「建 Release」的动作
grep -nE "gh release create|softprops/action-gh-release|actions/create-release|upload-release-asset|contents: write" .github/workflows/*.y*ml
```

判据：

- **(a) 命中 tag 触发 + (b) 命中建 Release 动作** → **方式 A**：你只推 tag，Release 交给 workflow。
- **(b) 命中，但触发条件是 `release: types: [published]` / `released`** → 它不建 Release，只是往已经存在的 Release 上挂产物 → 走 **方式 B** 由你建 Release，它会被 `release published` 事件叫醒，两者不冲突。**这种情况要跟用户说明一句**，让他知道产物是 workflow 补的。
- **(a) 命中但没有 (b)**（tag 触发只是跑测试/构建）→ **方式 B**。
- **拿不准就问**：YAML 里用了 reusable workflow / composite action、触发条件写的是 `on: [push]` 覆盖所有分支、grep 出来的文件和 tag 对不上号——这些都不是这个文件能替你判断的，把看到的东西告诉用户让他定。

> 除了「仓库已经有一个」这一种情况，**不要**为了本流程去新建或改动 workflow。本流程的全部发布动作都在本机可见，失败信息当场就能读到。

## 发布步骤

### 1. 提交本地改动到 GitHub

```bash
git status --short
git add -A
git commit -m "<这次的改动说明>"
git push origin "$BRANCH"
```

> 先看 `git status --short`：输出为空（本地没改动）就**跳过本步**直接进第 2 步，免得 `git commit` 报「nothing to commit」卡住。push 被拒（远端有新提交）就先 `git pull --rebase` 再推；被分支保护挡住就停下来问用户，别去改保护规则。

完成标准：`git push` 成功（或本步被跳过），`git status --short` 干净。

### 2. 升版本号（有 `package.json` 才需要）

**先看有没有 `package.json`**：

- **没有**：跳过本步，版本只由 tag 承载（纯文档仓库、其他语言的仓库都走这里）。若用户明确要改某个版本文件（`Cargo.toml`、`pyproject.toml`、`VERSION` 文件），问清楚改哪个、改成什么，再手改——**不要猜格式**。
- **有**：跑本 skill 自带的脚本（`<本 skill 目录>` 就是加载本文件时给出的 Base directory，换成实际路径）：

```bash
SKILL_DIR=~/.agents/skills/github-publish    # 换成实际加载本 skill 的目录
node "$SKILL_DIR/scripts/bump-version.js" "$VERSION"
```

它只替换 `version` 的**值本身**：不重新格式化 JSON、不碰依赖条目的 `version`、保持原缩进（2 空格/4 空格/tab）和结尾换行，一次改到位的是 `package.json` 的顶层 `version` 加上 `package-lock.json` 的顶层 `version` 和 `packages[""].version`（lockfile 是 v1、没有 `packages` 时只改顶层）。

脚本内置两道自保，看到它们就说明**文件没被写**，不要继续：
- 参数带 `v` 前缀 → 直接退出（防止 `vv0.2.0`）；
- 改完重新解析自检不通过、或压根找不到顶层 `version` → 退出并报错。

正常输出形如 `package.json: 0.1.0 -> 0.2.0`；文件不存在会打印「跳过」（纯 tag 发布的仓库就是这种）。

**然后自己再验一遍 diff**（脚本可能整个没用上，也可能这个仓库的版本号不止一处）：

```bash
git diff -- package.json package-lock.json
```

只应该看到 `version` 那几行变化（`package.json` 一处，lockfile 两处），**其它内容一行都不该变**。出现任何你不认识的改动，就 `git checkout -- package.json package-lock.json` 回滚，问用户之后再决定——不要带着看不懂的 diff 往下发布。

```bash
git add -A            # 第 1 步已确认工作区干净，此刻只有刚改的版本号
git commit -m "chore: 版本号升到 $VERSION"
git push origin "$BRANCH"
```

完成标准：`node -p "require('./package.json').version"` 等于 `VERSION`，commit 已推送，工作区干净（或本步整体跳过）。

### 3. 打 tag 并推送

tag 名 = `v$VERSION`（例如 `v0.2.0`）。

```bash
git tag -a "v$VERSION" -m "release v$VERSION"
git push origin "v$VERSION"
```

> 用 annotated tag（`-a -m`），别用 lightweight tag——GitHub 的 `--notes-from-tag` 和 Release 页面都要靠它上面的信息。
> **不要用 `git push --tags`**：那会把本地所有 tag 一起推上去，可能顺手把没打算发的版本推出去。
> 打 tag 前确认：第 2 步的版本号确实等于 `VERSION`（改了版本文件的仓库），commit 已推送，工作区干净。
> `git tag` 报 `already exists` = 这个版本号发过了，回到 `VERSION` 检查第 3 条换更高的版本，**别删 tag 重推**。

完成标准：`git push` 成功，`git ls-remote --tags origin "refs/tags/v$VERSION"` 能查到。

### 4. 产出 Release

#### 方式 A：靠仓库里已有的 workflow

不做任何 `gh release` 动作，直接进验证。但**先确认机器人真被叫醒了**：

```bash
gh run list -R "$OWNER/$REPO" --limit 5
```

看有没有一条由刚推的 tag 触发的新 run。

> **一条新 run 都没出现，就是没被触发**（workflow 的触发条件跟这个 tag 不匹配、workflow 被禁用、或它写在别的分支上）——停下来查清楚，别干等。确认有 run 之后：
> ```bash
> gh run watch <run-id> -R "$OWNER/$REPO" --exit-status
> ```
> 跑挂了就 `gh run view <run-id> -R "$OWNER/$REPO" --log-failed` 看日志，把失败原因报给用户。

#### 方式 B：gh CLI 建 Release

```bash
gh release create "v$VERSION" -R "$OWNER/$REPO" \
  --title "v$VERSION" \
  --generate-notes \
  --verify-tag
```

- `--verify-tag`：tag 不在远端就报错退出，防止 gh 拿默认分支的当前状态**偷偷替你造一个 tag**（造出来的 tag 指向的 commit 可能根本不是你要发的那个）。本流程第 3 步已经推了 tag，所以它一定会通过。
- 用户给了说明：把 `--generate-notes` 换成 `--notes "<说明>"`，或把说明写进文件用 `-F/--notes-file`。
- 有产物要上传：在命令末尾加文件名或通配符，例如 `./dist/*.zip`；要给资产起显示名就写成 `./dist/app.zip#app.zip`。
- 预发布版本加 `--prerelease`。
- **用户对说明/产物/时机拿不准时，先加 `-d` 只建草稿**（草稿只有维护者看得到），确认无误再 `gh release edit "v$VERSION" -R "$OWNER/$REPO" --draft=false` 发布。这是「不确定就缓一步」的正规做法，比发出去再删强得多。

完成标准：命令退出码为 0。

### 5. 验证

```bash
gh release view "v$VERSION" -R "$OWNER/$REPO" --json tagName,name,isDraft,isPrerelease,assets
```

完成标准：
- `tagName` **正好等于** `v$VERSION`（一个 `v`，不是 `vv0.2.0`、不是 `0.2.0`）；
- `isDraft` 为 `false`（没打算发草稿的话）；
- 要上传的产物都在 `assets` 里，数量对得上；
- 方式 A 还要补一条：`gh run list -R "$OWNER/$REPO" --limit 3` 里那条 run 是 `success`。

## 注意事项（踩过的坑）

- **不确定就停**：读不到、对不上、没见过、要取舍——任何一样拿不准，先问用户再动。问一句的成本，远低于错发一版。
- **tag 已存在 = 这版本发过了**：换更高的版本号重来。删 tag 重推会让已经贴出去的 Release 链接、别人 clone 下来的 tag 全部断掉；真要走这条路，必须让用户明确拍板。
- **只查一个 tag 判断不了「远端没 tag」**：`git ls-remote --tags origin` 整个为空，既可能是「没有你要的这个 tag」，也可能是「这仓库一个 tag 都没有」——两种情况处理方式不同，分不清就列出来看。
- **别把 `.git` 状态搞乱**：全程只做 `add` / `commit` / `tag` / `push`。不要 `reset --hard`、不要 `push --force`、不要删分支——发布不需要这些，出现「需要它们」的场面就是该问用户了。
- **tag 跟版本号一一对应**：版本 `0.2.0` → tag `v0.2.0`。
- **Release 名别多写一个 `v`**：写 `v0.2.0`，写成 `vv0.2.0` 是错的。
- **改版本号后必须看 diff**：`bump-version.js` 只改它认得的那两三处；仓库若还有别的版本文件（`app.json`、`Cargo.toml`、`manifest.json`…），脚本一律不碰，别让它们跟 tag 悄悄脱节。拿不准这个仓库的版本号一共写在几处，就问用户。
- **推送前必须核对账号**：远程归属、`git config user.name/email`、gh 登录账号三项都要用户确认后才推送。身份没配就推送，会产生不关联账号的「幽灵提交」（假邮箱 `用户名@主机名`），GitHub 上头像/贡献全丢，事后补不回来。
- **`gh` 登录账号要在仓库上有权限**：`gh auth status` 会列出 token 的 scope；对别人的仓库、组织仓库报 403 时先怀疑账号，别反复重试。本机有多个 GitHub 账号时用 `gh auth switch` 切到有权限的那个，切完把账号再亮给用户确认一次。
- **发布后的东西默认改不了**：仓库若开了 release immutability，发布后 tag 和资产都不能改也不能删。所以发布前把说明、产物、tag 名确认好；拿不准就先 `--draft`。
- **单次发布不要既靠 workflow 又自己建 Release**：方式 A 的场景下再跑一次 `gh release create` 只会拿到 `already exists`；方式 B 的场景下 Release 由你建，仓库若还有 `release: published` 触发的 workflow，那是来挂产物的，与你不冲突——但这句话要跟用户讲清楚。
- **失败了别自己想办法绕**：workflow 报错、权限 403、tag 冲突，先把原始输出报给用户，附上你的判断和建议，让他选回滚还是前进。
