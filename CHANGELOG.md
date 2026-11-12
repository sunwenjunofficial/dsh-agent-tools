# Changelog

## v0.2.0
- .gitignore 规则补充 Android 工程（local.properties、*.jks、.cxx/ 等）
- 清理 git 凭据链，去掉 Git Credential Manager 的弹窗干扰

## v0.1.1
- 添加 CHANGELOG

## v0.1.0
- 初版：netcheck.ps1、clash.mjs、github.ps1、git 凭据助手、两个 skill

## v0.2.1
- skill 补充：GitHub 直连不稳、代理 IP 共享导致 403、凭据链重置细节

## v0.2.2
- clash.mjs status 输出措辞修正

## v0.3.0
- clash.mjs: 管道名动态扫描（不再依赖 config.yaml 的 hash 与模板前缀）
- clash.mjs: 新增 port / start 命令，端口从内核 API 读取
- clash.mjs: 内核未响应时自动拉起 Verge 并轮询等待（--no-start 可关）
- netcheck.ps1: 自动拉起、出口 IP 校验、VERDICT 行、动态端口
- github.ps1: 代理端口改为动态探测
- skill 补充开发/聊天判定与稳定性设计

