# MacHead

<p align="center">
  <img src="Resources/logo.svg" width="128" height="128" alt="MacHead Logo" />
</p>

<h3 align="center">合盖即服务器 —— 把你的 MacBook 变成一台 Mac Studio</h3>

<p align="center">
  <em>Turn your closed MacBook into a headless Mac Studio.</em>
</p>

<p align="center">
  <a href="https://headlessmac.com"><img src="https://img.shields.io/badge/官网-headlessmac.com-blue.svg" alt="Website" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2012.0%2B-blue.svg" alt="Platform: macOS 12.0+" />
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-orange.svg" alt="Architecture: Apple Silicon | Intel" />
  <img src="https://img.shields.io/github/v/release/ox01024/MacHead" alt="Release" />
  <img src="https://img.shields.io/badge/license-Apache%202.0-green.svg" alt="License: Apache 2.0" />
</p>

**English** — MacHead is a free, open-source macOS menu-bar app that turns any MacBook — even one with a broken screen — into a headless server. Close the lid and it keeps working: internal display off, clamshell sleep handled, microphone muted, battery guarded. Includes a web console, a CLI (`machead`), remote access via Cloudflare Tunnel / Microsoft Dev Tunnels / FRP, and monitoring integrations (ServerStatus, Uptime Kuma). Apple Silicon & Intel, macOS 12+.

<p align="center">
  <img src="website/public/machead_console.jpg" width="720" alt="MacHead 远程控制台与偏好设置：实时监控 CPU/内存/GPU/电池,远程管理无头工作站" />
</p>

**MacHead** 是一款轻量、零依赖的 macOS 原生开源工具，专为把闲置 MacBook（内屏损坏的、打算合盖吃灰的、或想当专用桌面服务器/软路由的）重塑为一台高效、稳定、安全的 **Headless 无头工作站**。开盖是笔记本，合盖是服务器。

---

## ✨ 核心特性

- 🖥️ **合盖即服务器**：安全断开内置屏幕、支持合盖运行，笔记本秒变安静省电的无头主机，内屏不再常亮发热、损耗排线
- ⌨️ **智能防误触**：进入无头模式后自动锁死内置键盘与触控板，外接键鼠完全不受影响；平时接上外接鼠标也会自动屏蔽触控板
- 🔇 **隐私保护**：进入无头模式时自动物理静音麦克风防窃听，退出时自动还原原始音量
- 🔋 **电池守护**：意外断电且电量低于安全阈值时，自动解除防睡眠并允许深度休眠，避免长期合盖搁置把电池「饿死」
- 📊 **远程 Web 控制台**：手机或电脑浏览器实时查看 CPU / 内存 / 电量并远程开关功能；首次启动随机生成管理密码，杜绝内网越权访问
- ↔️ **内网穿透套件**：**Cloudflare Tunnel** / **Microsoft Dev Tunnels** / **FRP** 三套方案统一管理，把本机 SSH/Web 服务安全暴露到公网，随时随地远程接管设备
- 📡 **监控与告警**：原生接入 **哪吒监控**、**ServerStatus**、**Uptime Kuma**，配合温度告警（Bark / Telegram 通知），无人值守心里有数
- 🧹 **拖走即卸载**：默认对系统零写入，App 拖入废纸篓即完全卸载；可选组件随用随建、关开关即清理

---

## 🚀 下载安装

**方式一：官网下载（推荐，始终最新）**

前往 [headlessmac.com](https://headlessmac.com) 下载 DMG 镜像，双击打开后将 MacHead 拖入「应用程序」文件夹即可。支持 macOS 12.0+（Monterey 及以上），Apple Silicon 与 Intel 通用。安装后的新版本通过自动更新静默推送，无需手动重装。

**方式二：GitHub Releases**

前往 [GitHub Releases](https://github.com/ox01024/MacHead/releases) 页面下载历史版本的 DMG。

---

## ⚡ 快速上手

**菜单栏一键控制**

启动后，菜单栏出现 MacHead 图标。点击图标即可一键「开启 Headless 模式 / 恢复内屏显示」，并实时查看显示器、电源、温度状态。各项功能（自启、防误触、穿透、监控等）都在「偏好设置」中管理。

**命令行控制**

在偏好设置中开启「machead 命令行工具」后，可直接在终端（含 SSH）控制：

```bash
machead --status    # 查询当前状态 (headless / normal / offline)
machead --enable    # 开启无头模式
machead --disable   # 恢复正常模式
```

**远程 Web 控制台**

在偏好设置中开启后，浏览器访问 `http://<本机局域网IP>:8080`（如 `http://192.168.1.100:8080`，默认端口为 8080，可在偏好设置中自定义修改），用户名 `admin`，密码为首次启动随机生成（可在偏好设置中修改）。

---

## 🔒 权限设置说明

屏蔽内置键盘 / 触控板需要 macOS 特殊授权（偏好设置面板会在功能未生效时给出引导）：

1. **辅助功能权限**：「系统设置 → 隐私与安全性 → 辅助功能」中允许 **MacHead**。用于拦截并丢弃内置键盘的物理按键。
2. **输入监听权限**：「系统设置 → 隐私与安全性 → 输入监听」中允许 **MacHead**。用于独占并锁定内置触控板。

---

## 🗑️ 卸载说明

遵循 macOS 原生习惯：**将 App 拖入废纸篓即完成卸载**，无需任何卸载程序。

- **默认安装**（未开启可选组件）：对系统零写入，拖入废纸篓即 100% 清理干净。
- **开启过可选组件**：清理在关闭开关的那一刻即时完成——
  - 关闭「machead 命令行工具」→ 立即删除 `/usr/local/bin/machead`
  - 登出 Dev Tunnels → 立即清除 Keychain 登录凭据
  - 应用内安装的 devtunnel CLI 位于 `~/Library/Application Support/MacHead/`，删除该目录即可

---

## 🔐 隐私与遥测

- **遥测完全匿名**：仅收集随机生成的本地 UUID、系统/应用版本、CPU 架构与功能开关状态（布尔值），**不含**任何硬件序列号、网络地址、账号凭据或使用内容。
- **一键退出**：偏好设置 → 常规设置 → 关闭「匿名使用统计」即不再发送任何数据。
- **零第三方 SDK**：自建轻量 HTTP 上报，无任何广告/分析组件。
- 完整字段清单与数据处理方式见 [PRIVACY.md](PRIVACY.md)；漏洞上报方式见 [SECURITY.md](SECURITY.md)。

---

## 🛠️ 从源码构建

开发环境零第三方依赖，只需 macOS 自带的 Xcode Command Line Tools：

```bash
git clone https://github.com/ox01024/MacHead.git
cd MacHead
./build.sh --no-install   # 编译通用二进制,产物留在当前目录 ./MacHead.app
./build.sh                # 编译并安装到 /Applications(会重启 App)
```

无需 Apple Developer 证书(ad-hoc 签名)、无需任何第三方包管理器。`Resources/` 下的可选监控/穿透二进制不入库,缺失时构建依旧成功。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

```
MacHead/
├── Sources/            # Swift 源代码（App、CLI、各服务模块）
├── Resources/          # 应用资源（Info.plist、图标、Web 面板页面）
├── Scripts/            # 构建辅助脚本（图标生成等）
├── website/            # 官网 headlessmac.com（Vite + Cloudflare Pages）
├── docs/               # 深入文档
├── build.sh            # 一键构建安装脚本
└── .github/workflows/  # CI/CD（版本发布、官网部署）
```

欢迎提交 [Issue](https://github.com/ox01024/MacHead/issues) 与 Pull Request：反馈 bug 请附上 macOS 版本与机型；功能建议请先描述使用场景。仓库维护者通过推送 `v*` 附注标签触发 GitHub Actions 自动发版（构建、DMG、R2 上传、appcast、GitHub Release 一条龙）。

---

## 📄 开源协议

本项目源代码采用 **Apache License 2.0**，详情见 [LICENSE](LICENSE)。

- **客户端完全开源**：本仓库包含 macOS 客户端的全部源代码。
- **第三方组件**：构建期拉取的 frp、nezha-agent、cloudflared 等开源组件归属其原作者，许可信息见 [NOTICE](NOTICE)；Microsoft Dev Tunnels CLI 为专有组件，不分发、不捆绑，由用户按微软条款自行安装。
