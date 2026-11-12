# GitHub 版本控制与自动发布

**先分清"开发"和"聊天"。** 只有真正的开发任务才发 GitHub；聊天、答疑、调研一律不建仓库、不推送。

算开发（三条全中）：产出可复用代码/工程文件；用户要的是"做出或改好一个东西"；产物有保留价值。
不算开发：问答调研；一次性排查脚本；作业/报告/文档排版；用户只是看看效果。**边界不清先问。**

**确认是开发后：每次为孙闻骏开发功能/项目，收尾时必须提交并推送到 GitHub，并且每个版本都打 tag。** 没有推送不算完成。

## 硬性约定

| 项 | 约定 |
|---|---|
| 账号 | `sunwenjunofficial` |
| 可见性 | **公开 public** |
| 仓库粒度 | 每个项目一个独立仓库（仓库名 = 项目目录名，小写连字符） |
| 分支 | `main` |
| 版本号 | semver tag `vX.Y.Z`，首次自动 `v0.1.0` |
| 提交信息 | Conventional Commits 英文前缀 + 中文或英文描述，如 `feat: 支持筛选 RAW+JPG`、`fix: 修复缩略图闪烁` |

**版本号怎么升**（拿不准就 patch）：

- `patch`（默认）：修 bug、小改动、文案、样式
- `minor`：新增功能，向后兼容
- `major`：不兼容的大改版
- `none`：只提交不打 tag（仅用于中间存档，正常收尾不要用）

## 一条命令收尾

```powershell
$gh = "$env:USERPROFILE\.dsh\tools\github.ps1"
powershell -ExecutionPolicy Bypass -File $gh -Action publish -ProjectPath <项目目录> `
  -Message "feat: 本次做了什么" -Bump patch
```

它按顺序做：`git init`（若无）→ 补 `.gitignore` → `git add -A` → **密钥扫描**（有命中直接中止）→ commit → 打 tag → 没有 origin 就调 API 建**公开**仓库并挂上 → `git push --follow-tags`（直连失败自动改走 Clash 7897 并记进该仓库 config）→ 打印仓库地址/commit/tag。

首次使用前确认 token 可用：

```powershell
powershell -ExecutionPolicy Bypass -File $gh -Action whoami
```

## 收尾流程（每次开发都走一遍）

0. **先 `-Action dirty -ProjectPath <项目根>` 扫一遍**：列出有未提交改动 / 有未推送 commit 的仓库。
   多个会话轮番改同一个项目时，这一步能立刻发现"改了但没同步"的漏网项。
1. **跑通验证**：能跑测试就跑测试，能起服务就起服务看一眼；不要提交一个自己明知坏掉的版本。
2. **清垃圾**：把截图、`__pycache__`、临时 `.py`/`.js` 调试脚本、构建产物挡在版本库外（`.gitignore` 由脚本自动补）。
3. **扫密钥**：直接 `-Action audit -ProjectPath <dir>`；有命中就清理后重来，**不要**用 `-Force` 绕过。
4. **写提交信息**：说清这次改了什么，不要 `update`、`fix bug`、`改了一下`。
5. **publish**：选择 bump 级别。
6. **汇报**：把仓库 URL、版本号、commit 短 hash 一并告诉用户。

## 自动推送钩子（第二道保险）

`publish` 成功后会往仓库里装一个 `.git/hooks/post-commit`：**之后任何一次 `git commit`（不管哪个会话做的）都会自动推到 origin**，直连失败自动改走 Clash。

- 它只保证"commit 过的都上去"，**管不了"改完没 commit"**——所以第 0 步的 `dirty` 检查不能省。
- 新仓库第一次 publish 后自动安装；老仓库可以补：`-Action hook -ProjectPath <dir>`。
- 钩子永远 `exit 0`，push 失败也不会卡住 commit，只会打一行提示。
- 想临时不推：`git commit` 前设环境变量 `GIT_DSH_NOPUSH=1`（钩子会跳过）。

## 新项目从哪开始

新建项目默认放 `C:\Users\SunWenjun\Documents\projects\<项目名>`，不要扔在 `default-workspace` 那种堆满临时文件的地方——那里没有版本控制，也没法整体推送。

## 凭据

- Token 用 DPAPI 加密存在 `~/.dsh/secrets/github-token.bin`，只有本机本用户能解。
- git 通过 `credential.https://github.com.helper` 调用 `~/.dsh/tools/git-credential-github.ps1` 取 token，**仓库里不出现明文 token**。
- 写入/更换：`-Action token-save -Token ghp_xxx`；撤销：`-Action token-clear`。
- **永远不要把 token 写进代码、`.git/config`、提交信息或文档里。**
- `~/.gitconfig` 里 `[credential "https://github.com"]` 第一行必须是**空的 `helper =`**（重置列表），用来屏蔽系统级 Git Credential Manager；否则每次 push 都会弹窗或报 `Cannot prompt because user interactivity has been disabled`。`github.ps1` 调用 git 时还会设 `GCM_INTERACTIVE=never` 兜底。

## .gitignore 策略

脚本会自动补齐常见规则（Python / Node / Rust / Gradle / Android / 编辑器 / 系统垃圾）。
**注意**：`raw-analysis`、`dr-analysis` 这类分析目录里是几十上百 MB 的 DNG/JPG 素材，**不适合进 Git**（GitHub 单文件 100 MB 硬限制，仓库也会变砖）。素材留在本地，仓库只放代码和小样本。

## 排错

| 现象 | 处理 |
|---|---|
| `no GitHub token stored` | 让用户重新提供 PAT，`-Action token-save` |
| `401 Bad credentials` | token 过期或被撤销，重新生成 |
| `403` / `rate limit` | 代理共享出口 IP 被限流；确认 token 已生效（认证请求按 token 计额） |
| push 卡住/超时 | 正常，脚本会自动改走 `http.proxy=http://127.0.0.1:7897` 重试；仍失败先跑 `netcheck.ps1` |
| `remote: Support for password authentication was removed` | 没有走 credential helper，检查 `git config --global --get-all credential.https://github.com.helper` |
| 文件超过 100 MB | GitHub 硬限制，用 `.gitignore` 排除或用 Releases 挂附件 |
| **仓库描述里的中文变成 `?????`** | PowerShell 5.1 的 `Invoke-RestMethod` 在 ContentType 不带 charset 时把字符串体按 ISO-8859-1 编码，CJK 全变问号。`github.ps1` 已改为传 **UTF-8 字节**；已建坏的仓库用 `-Action describe -ProjectPath <dir> -Description "..."` 修回来 |
| 别的会话改过项目，GitHub 上却没有 | 那个会话没 commit（钩子帮不了）。跑 `-Action dirty` 找出来，再 `-Action publish` 补上 |
| `.ps1` 改完行为诡异（某条赋值"没生效"） | 脚本里有中文注释会导致编码错乱，甚至吞掉换行。**`.ps1` 只允许 ASCII**，中文放 README/skill 里 |

> 提交信息、README、tag 走的是 git 协议，不受这个 bug 影响；只有走 REST API 的字段（仓库描述、issue/PR 正文）会中招。
