---
name: chrome-extension-publish
description: 发布 Chrome 扩展（Chrome Web Store）：本地全量测试门禁 → 升版本 → 提交推送 → 打 tag 触发 GitHub Actions 自动上传并提交审核 → 确认审核状态与回滚。任何不确定都用 ask_user_question 弹窗向用户提问，绝不猜。当用户说「发版 / 发布扩展 / 上架 / 更新商店版本 / 打个 tag 发一下 / 提交审核 / 回滚版本」时使用。
---

# Chrome 扩展发版流程

发布 = 本地测试全绿 + 升版本 + 提交推送 + 打 tag（触发自动上传与提交审核）+ 确认结果。
**发布是单向动作**（tag 与审核提交推出去很难收回），本流程对「不确定」零容忍。

## 总原则（强制）

**任何不确定都必须调用 `ask_user_question` 弹窗向用户提问，不得自行选择默认值。** 至少包括：

- 仓库/分支/版本号/manifest 路径读不到，或存在多个候选（多个 remote、多个 manifest、版本对不上）；
- 商店线上版本读不到，无法确认新版本更大；
- 推送所需密钥缺失（列出缺哪几个，附带补键位置）；
- 本地缺 Playwright 或浏览器（问：自动安装 / 用 Docker 镜像 / 中止）；
- 测试失败（问：先修 / 中止，跳过必须明确告知风险）；
- 要提交的文件里出现 zip、`.env`、临时脚本、日志等不该进仓库的内容；
- 要执行单向动作：push tag、提交审核、撤回审核、回滚版本。

一切写操作前，先用一句话把「马上要做什么」告诉用户；单向动作必须拿到明确确认后才执行。
**绝不读取、打印、写入、提交任何密钥值**；只检查密钥名字是否存在。

## 阶段 0：发版前体检（只读，不改任何东西）

1. **仓库**：`git rev-parse --show-toplevel`、`git remote -v`、当前分支、`git status --porcelain`。多 remote / 有未提交改动 → 弹窗问。
2. **版本源**：读 `package.json` 的 version；探测 manifest（`public/manifest.json` 或 `manifest.json`）；两处必须一致。
3. **发布配置**：探测 `.github/workflows/publish-cws.yml`（或 grep 含 `chrome-webstore-upload` 的 workflow），读出扩展 ID 和需要的 Secrets 名。找不到 workflow → 弹窗问是否要先配置自动发布。
4. **推送密钥**：`gh auth status`；`gh secret list`（**只看名字**），逐个核对 CLIENT_ID / CLIENT_SECRET / REFRESH_TOKEN / PUBLISHER_ID。缺哪个就明确列出，并弹窗问：现在去补 / 只跑本地测试 / 中止。
5. **商店线上版本**：用扩展 ID 抓 `https://chromewebstore.google.com/detail/x/<扩展ID>`，解析“版本 X.Y.Z”。读不到 → 弹窗问（改为用户手动确认线上版本）。
6. **版本比较**：待发版本必须 **大于** 线上版本。不满足 → 弹窗问（升版本 / 中止）。
7. **Playwright 可用性**：`node -e "require.resolve('playwright')"`；再确认 Chromium 可启动（试跑冒烟脚本，或 `npx playwright install --dry-run chromium`）。缺失 → 弹窗三选一：
   - A. 自动安装：`npx playwright install chromium`（推荐，本地一次即可）；
   - B. 用官方 Docker 镜像跑冒烟：`docker run --rm -v "$PWD":/work -w /work -e PW_NO_SANDBOX=1 mcr.microsoft.com/playwright:v<与本地 @playwright/test 主版本一致的标签>-noble node scripts/smoke-production.cjs`；
   - C. 中止发版。

## 阶段 1：本地测试门禁（必须全绿，才允许继续）

| # | 测试 | 命令 | 说明 |
|---|---|---|---|
| 1 | 类型检查 | `npm run typecheck:app` | 必跑 |
| 2 | 回归：单测 | `npm test` | 必跑（全量单测，含回归用例） |
| 3 | 回归：E2E | `npx playwright test tests/e2e/ghost.spec.ts`；再按改动挑 `tests/e2e/sidepanel.spec.ts` 的核心用例 | 必跑（E2E 存在时） |
| 4 | 恢复生产构建 | `npm run build` | **必跑**：第 3 步会把 dist 重建为 E2E 测试版，不恢复就会拿测试包去冒烟/发布 |
| 5 | 冒烟：生产包 | `npm run build` 后跑 `node scripts/smoke-production.cjs` | 必跑（脚本不存在则临时生成，见下） |
| 6 | 压力测试（按需） | `npx playwright test tests/e2e/stress.spec.ts` | 涉及多标签/拖拽/性能/布局改动时跑 |

**生产冒烟脚本缺失时**：按当前代码现场生成（最小覆盖：加载扩展 → 侧边栏行数 == chrome.tabs.query 数 → 点击行激活 → 外部关闭标签后行消失 → 强杀 Service Worker + 关标签后无幽灵/重复行 → 捕捉页面 JS 异常）。运行前把脚本要点告诉用户，运行后保留文件并告知路径。

**任一步失败**：立即停止，不 commit、不 tag、不发布；汇报失败的层、命令、错误摘要，并用 `ask_user_question` 问下一步（先修 / 中止）。

## 阶段 2：升版本

- 同时修改 `package.json` 与 manifest 的 version，保持一致，且大于商店线上版本；
- 改完用 node 校验两处相等；
- 不使用 `npm version`（会改 lockfile、自动打 tag）。

## 阶段 3：提交代码

- 只 `git add` 必要文件；显式排除 zip 安装包、`.env`、`CONTEXT.md`、临时脚本、日志、`dist/`；
- 提交前把 `git diff --cached --stat` 给用户看；发现可疑文件 → 弹窗确认；
- commit message 含版本号与变更摘要。

## 阶段 4：打 tag 并推送（单向动作，必须先弹窗确认）

1. `git tag -a vX.Y.Z -m "release vX.Y.Z"`；
2. 确认远端没有同名 tag（`git ls-remote --tags origin`）；
3. 推送分支与 tag（tag 触发 workflow：构建 → 上传 → **提交审核**）；
4. 若用户只想上传草稿：`gh workflow run publish-cws.yml -f publish=false`（不提交审核）。

## 阶段 5：监控流水线

- `gh run list --workflow=publish-cws.yml -L 1 --json databaseId,status,conclusion`
- `gh run watch <id> --exit-status`
- 成功判据：`Upload to Chrome Web Store` ✓ 且 `Submit for review` ✓（只上传草稿时为上传 ✓、提交跳过）。
- 失败：`gh run view <id> --log-failed` 取错误 → 按「常见坑」分类处理 → 弹窗汇报。

## 阶段 6：结果确认与汇报

- 告诉用户：已提交审核；**审核通过前商店线上版本不变**；到开发者后台看「审核中/已发布」。
- 汇报模板：版本 / tag / Actions 链接 / 上传与提交审核结果 / 测试清单与结果 / 下一步。

## 阶段 7：失败与回滚

- **审核前撤回**：开发者后台取消提交（或 v2 API `cancelSubmission`）。
- **已上线回滚**：开发者后台 `Rollback to a previous version`。
- **重新发布**：升新版本号重走流程；**永不重用已发布过的版本号或 tag**。
- 任何回滚/撤回都是单向动作 → 先弹窗确认。

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| Actions 报 401 / invalid_grant | refresh token 过期（OAuth 应用停在“测试”状态只有 7 天） | 重新生成 token，更新 CHROME_REFRESH_TOKEN |
| 上传报版本已存在 / 必须更大 | 版本号没升或未大于线上 | 升两处版本号后重试 |
| tag 与 package.json 版本不一致 | 打错 tag | 未推送可删本地 tag 重打；已推送只能升版本 |
| 上传失败提示需要 CRX | 商店开了“验证上传（Verified Uploads）” | 关掉该设置，或改为上传签名 CRX |
| 审核被拒 | 权限说明/隐私/单一用途不合规 | 看后台理由，改商店信息后重新提交 |
| 提交后线上版本没变 | 正常：审核通过后才上线 | 等审核，不要重复提交 |

## 安全红线

- 不读取、不打印、不写入、不提交任何密钥值；只检查 Secrets 名字。
- 不把 token 写进日志、文件、commit message。
- 不绕过测试门禁；确需跳过必须弹窗并明确告知风险。

## 交付物

- 成功：发版汇报（版本 / tag / Actions 链接 / 上传与提交审核结果 / 测试结果 / 审核说明）。
- 失败：卡在哪一层、错误分类、建议动作、是否需要回滚。
