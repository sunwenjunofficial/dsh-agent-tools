# dsh-agent-tools

给 DeepSeek Harness 智能体用的两个小工具集：**网络自检/Clash 控制**、**GitHub 版本发布**。
运行环境：Windows + Windows PowerShell 5.1 + Node.js 18+。

## tools/netcheck.ps1 — 网络自检

```powershell
powershell -ExecutionPolicy Bypass -File tools\netcheck.ps1
```

依次检查：Clash Verge 进程 → 混合端口 7897 → Windows 系统代理 → 8 个目标站点的「直连 vs 代理」状态码，最后给出处置建议。退出码非 0 表示有问题。

## tools/clash.mjs — Clash Verge 内核控制

Clash Verge 关闭了 TCP 版 external-controller，只监听 Windows 命名管道。本工具用 Node 直连管道发 HTTP 请求，无需开端口。

```powershell
node tools\clash.mjs status                 # 模式 / 端口 / 各组当前节点
node tools\clash.mjs groups                 # 所有选择器组
node tools\clash.mjs delay Proxies          # 全部节点测速排序
node tools\clash.mjs best  Proxies          # 切到最快节点
node tools\clash.mjs use   GitHub Proxies   # 服务级分组指向 Proxies
node tools\clash.mjs mode  rule             # rule / global / direct
node tools\clash.mjs env                    # 打印代理环境变量
```

管道名自动从 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\config.yaml` 推导；也可用 `CLASH_PIPE` 环境变量覆盖。

## tools/github.ps1 — 一键提交 + 打 tag + 推送

```powershell
# 1) 存 token（DPAPI 加密，仅本机本用户可解）
powershell -File tools\github.ps1 -Action token-save -Token ghp_xxx
powershell -File tools\github.ps1 -Action whoami

# 2) 收尾发布
powershell -File tools\github.ps1 -Action publish -ProjectPath .\myproj `
  -Message "feat: 新增导出功能" -Bump minor
```

发布流程：`git init`（若无）→ 补 `.gitignore` → `git add -A` → **密钥扫描**（命中即中止）→ commit → 打 semver tag → 无 origin 时调 API 建公开仓库 → `git push --follow-tags`（直连失败自动改走 Clash 7897）。

其他动作：`ignore` 补 `.gitignore`、`audit` 只扫描不提交、`status` 看仓库状态、`token-clear` 撤销。

### 版本号

| Bump | 用于 |
|---|---|
| `patch`（默认） | 修 bug、小改动 |
| `minor` | 新增功能 |
| `major` | 不兼容的大改版 |
| `none` | 只提交不打 tag |

首次发布固定 `v0.1.0`。

## tools/git-credential-github.ps1 — git 凭据助手

给 git 用的 credential helper，从 DPAPI 文件取 token，仓库里不会出现明文密码。注册方式：

```powershell
git config --global credential.https://github.com.helper `
  '!C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:/Users/<you>/.dsh/tools/git-credential-github.ps1"'
```

## skills/ — 智能体技能说明

- `clash-network`：本机代理拓扑、各语言/工具的代理差异、已知陷阱（DNS 污染、TUN 关闭的影响、`web_fetch` 的 SSRF 限制）。
- `github-version-control`：开发收尾的强制流程、提交信息规范、排错表。

## 已知限制

- 只针对本机这套 Clash Verge 布局，端口/管道名写死在脚本默认值里，换机器要改。
- `github.ps1` 建仓走 GitHub REST API，需要 `repo` 权限；token 过期后 `whoami` 会返回 401。
