# Clash Verge 代理使用与网络自检

本机装了 Clash Verge（内核 verge-mihomo），用来访问公网。**遇到任何"连不上/超时/证书错误/被墙"的迹象，先按本 skill 自检并自行修复，不要直接放弃或改口说做不到。**

## 本机事实（2026-11 实测，变动后请重新核对）

| 项 | 值 |
|---|---|
| 主程序 | `C:\Program Files\Clash Verge\clash-verge.exe`（进程 `clash-verge`） |
| 内核进程 | `verge-mihomo`（mihomo v1.19.32） |
| 配置目录 | `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev` |
| 混合端口 | `127.0.0.1:7897`（HTTP 代理 + SOCKS5 同端口） |
| 其他端口 | socks-port / http port 均为 0（未单独开启） |
| TUN 模式 | **关闭**（只有走代理设置的程序才会被代理） |
| 系统代理 | **开启**（注册表 `HKCU\...\Internet Settings` → `127.0.0.1:7897`，带内网 bypass） |
| 控制接口 | 只开**命名管道** `\\.\pipe\verge-mihomo-production-<hash>`；`enable_external_controller: false`，**9097 端口没在监听** |
| 当前订阅 | RioLU（`RdX6Y8TY3Lwq`），54 个节点，HK 直连 40ms 级 |
| 模式 | rule |

代理组（Selector，每组可选 56 项，默认都指向 `Proxies`）：`Proxies` / `AI` / `GitHub` / `Google` / `YouTube` / `Netflix` / `Disney` / `Telegram` / `TikTok` / `Apple` / `Microsoft` / `Bilibili` / `Game` / `✈️Final` / `🎯Direct`。

## 第一步永远是自检

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\tools\netcheck.ps1"
```

输出会告出：进程在不在、7897 通不通、系统代理值、以及"直连 vs 代理"逐个站点的状态码。按结论处理：

- 进程不在 → 启动 `clash-verge.exe`（`Start-Process 'C:\Program Files\Clash Verge\clash-verge.exe'`），等 5 秒再测。
- 7897 不通但进程在 → Verge 可能处于"已停止内核"，让用户点一下界面开关，或重启 Verge。
- 代理通但某站仍失败 → 该站走的是 DIRECT 或被服务级分组指定到 `🎯Direct`，用下方 `clash.mjs` 把 `GitHub` / `Google` / `AI` 组切到 `Proxies`。
- 代理本身通、延迟高 → `clash.mjs best Proxies` 换最快的节点。

## 让命令行工具走代理

```powershell
$env:HTTP_PROXY  = 'http://127.0.0.1:7897'
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'
$env:ALL_PROXY   = 'http://127.0.0.1:7897'
$env:NO_PROXY    = 'localhost,127.0.0.1,::1'
```

各工具差异（都是踩过的坑）：

| 工具 | 做法 |
|---|---|
| `curl.exe` | 认 `HTTP(S)_PROXY` 环境变量；或显式 `-x http://127.0.0.1:7897`。内网/直连测试用 `--noproxy '*'` |
| `git` | 认环境变量；也可 `git -c http.proxy=http://127.0.0.1:7897`。SSH 远端（22 端口）不走 HTTP 代理，要改成 `ssh -o ProxyCommand=...` 或直接用 HTTPS |
| Node `fetch` | **默认不读环境变量**。要 `NODE_USE_ENV_PROXY=1` + `HTTPS_PROXY=...`（Node ≥ 24 可用） |
| Python | `urllib`/`requests` 认环境变量。注意用 `C:\Users\SunWenjun\.dsh\dsh-runtimes\...\python\python.exe`，`python.exe` 那个 WindowsApps 别名是坏的 |
| pip | `pip install --proxy http://127.0.0.1:7897 ...` 或 `PIP_PROXY` |
| 浏览器 | 走系统代理，无需额外设置 |

## 切换节点 / 模式（命名管道 API）

Verge 关掉了 TCP controller，只能走命名管道。`~/.dsh/tools/clash.mjs` 已封装好：

```powershell
node "$env:USERPROFILE\.dsh\tools\clash.mjs" status            # 模式/端口/各组当前节点
node "$env:USERPROFILE\.dsh\tools\clash.mjs" delay Proxies     # 全部节点测速排序
node "$env:USERPROFILE\.dsh\tools\clash.mjs" best  Proxies     # 切到最快节点
node "$env:USERPROFILE\.dsh\tools\clash.mjs" use   GitHub Proxies  # 把 GitHub 分组指向 Proxies
node "$env:USERPROFILE\.dsh\tools\clash.mjs" mode  rule        # rule / global / direct
```

管道名是 `verge-mihomo-production-` + `config.yaml` 里 `external-controller-pipe` 的 hash（`config.yaml` 里写的 `sidecar-release-` 前缀是模板占位，别照抄）。

## 已知陷阱

1. **DNS 污染**：`www.google.com` 在本机解析到 `104.244.42.197`（Twitter 的 IP）。所以"先解析再连接"的工具（包括 DSH 的 `web_fetch`）会直接失败。杜搜受限站点别用 `web_fetch`，用 `curl -x` 或浏览器 CDP。
2. **`web_fetch` 的 SSRF 保护**：目标域名解析到非公网 IP 时会报 `resolves to a non-public IP address`，这是工具限制，不是网络故障。换 `curl.exe` 走代理。
3. **`web_fetch` 对空响应体报 `unsupported content type "unknown"`**：说明**连接是通的**（只是 204 没内容），别误判成网络故障。
4. **TUN 关闭** ⇒ 不读系统代理的程序（部分 Electron 应用、Java、老 .NET）根本不走代理。要么给它们单独设代理，要么在 Verge 里开 TUN（需要管理员，会改路由）。
5. **GitHub 直连看运气**：实测同一台机器上 `api.github.com` 直连时好时坏，`git push` 直连出现过 21 秒超时；走 7897 稳定。`github.ps1` 已实现"先直连、失败自动改走代理并把 `http.proxy` 记进该仓库"。
6. **节点分组是服务级的**：`GitHub` 组指到 `🎯Direct` 时 Git 操作会走直连并可能失败；排查时先 `clash.mjs status` 看对应分组指向谁。
7. 订阅到期/流量用尽会表现为"代理连着但全部节点 5xx 超时"，用 `clash.mjs delay Proxies` 一看便知（全 fail）。
8. **代理 IP 是共享的**：`api.github.com` 未经认证走代理常返回 `403 API rate limit exceeded`（出口 IP 被别人用完了）。这不是网络坏了——用 token 认证的请求按 token 计额，不受影响。
