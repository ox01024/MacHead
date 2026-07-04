---
name: appcast-management
description: Detailed schema, rules, and URL configurations for managing the MacHead OTA appcast.json metadata file.
---
# MacHead appcast.json 管理规范

本技能定义了 MacHead 客户端自动更新（OTA）版本描述文件 `appcast.json` 的标准 Schema、字段规则以及托管路径。任何代理人在对应用进行版本升级或修改升级逻辑时，必须严格遵守本规范。

## 1. 物理托管路径
- 版本清单文件必须保存在前端静态资产目录中：`website/public/appcast.json`。
- **发布机制**：严禁手动向 Cloudflare R2 上传该 JSON 文件。它必须通过 Git 提交推送到 GitHub，由 Cloudflare Pages 原生自动部署，最终对外提供公网访问：`https://headlessmac.com/appcast.json`。

## 2. 字段 Schema 定义
`appcast.json` 包含以下 5 个核心必填字段：

```json
{
  "version": "1.1.0",
  "build": 2,
  "pubDate": "2026-07-04",
  "url": "https://releases.headlessmac.com/MacHead-v1.1.0-macos-universal.dmg",
  "releaseNotes": "1. 修复了插拔电源时的电池保护误触发问题；\n2. 优化了外接屏幕断开后的恢复速度。"
}
```

### 字段详解：
- `version` (String): 语义化版本号（SemVer）。比对逻辑采用 `String.compare(_:options:.numeric)`。
- `build` (Int): 整数构建号。若 `version` 一致，但 `build` 更大，客户端也会触发更新。
- `pubDate` (String): 版本发布日期，格式必须为 `YYYY-MM-DD`。
- `url` (String): 安装包下载直链。必须使用绑定的 R2 存储桶子域名：`https://releases.headlessmac.com/MacHead-v[Version]-macos-universal.dmg`。
- `releaseNotes` (String): 面向普通用户的通俗升级日志。可以使用换行符 `\n`。

## 3. 升级检测逻辑 (Swift 客户端)
- 客户端使用单例 `UpdateManager.shared` 进行检测。
- 自动检测默认在 App 启动 3 秒后静默触发；手动检测在偏好设置（`PreferencesView.swift`）底部的“检查更新...”按钮触发。
- 比较逻辑：
  ```swift
  let versionResult = cloudVersion.compare(currentVersion, options: .numeric)
  if versionResult == .orderedDescending {
      return true
  } else if versionResult == .orderedSame {
      return cloudBuild > currentBuild
  }
  return false
  ```
