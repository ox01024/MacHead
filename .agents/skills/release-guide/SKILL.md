---
name: release-guide
description: Complete step-by-step guide for building and releasing new versions of MacHead using Git tags and GitHub Actions CI/CD.
---
# MacHead 版本发布与 CI/CD 流水线指南

本技能规定了 MacHead 项目的版本发版流程与 CI/CD 自动化流水线的操作规范。

## 1. 发布流程 (Git Tag 驱动)
项目采用了完全由 Git 标签驱动的云端自动化发布。发版时，严禁本地手动编译 DMG 或手动上传 R2 存储桶。请遵循以下步骤：

### 步骤一：在本地仓库打版本标签
标签名称必须符合 `v*` 格式（如 `v1.1.0`），且必须附带 `-m` 参数写入**给普通用户看的通俗升级日志**（不支持技术提交细节）：

```bash
git tag -a v1.1.0 -m "1. 修复了插拔电源时的电池保护误触发问题；\n2. 优化了外接屏幕断开后的恢复速度。"
```

### 步骤二：推送标签至远程仓库
将标签推送至 GitHub，云端会自动识别并触发 `.github/workflows/release.yml` 流水线：

```bash
git push origin v1.1.0
```

---

## 2. 云端 Actions 流水线工作细节
流水线触发后，会在 `macos-latest` 环境中执行以下原子任务：
1. **源码编译**：执行 `./build.sh` 编译 Universal 二进制。
2. **DMG 打包**：通过 `hdiutil create` 隐藏打包生成 `MacHead-v[Version]-macos-universal.dmg`。
3. **R2 部署**：调用 Wrangler 命令行，使用 GitHub Secrets 鉴权将安装包静默上传至 Cloudflare R2 的 `headlessmac-releases` 存储桶中。
4. **回写 appcast.json**：
   - 提取您在打 Tag 时手写的注释内容，将其更新到 `website/public/appcast.json` 的 `releaseNotes` 中。
   - 使用 GitHub Bot 将 JSON 的变更提交并 Push 回 `main` 分支，进而触发 Cloudflare Pages 重构热更新。
5. **双轨日志发布**：
   - 自动在 GitHub 上创建一个对应的 Release 网页，并将编译好的 DMG 作为附件挂载。
   - **自动汇总技术提交**：Release 网页的 Body 部分会自动基于两个版本之间的 Commit 历史生成详细的技术细节变更日志，与面向用户的普通日志实现分离。

---

## 3. 流水线环境变量 (Secrets)
若流水线报错或需要重构，请确保 GitHub 仓库的 Settings 中已正确配置以下密钥：
- `CLOUDFLARE_API_TOKEN`: 拥有 R2 桶读写编辑权限的永久 Cloudflare API 令牌。
- `CLOUDFLARE_ACCOUNT_ID`: Cloudflare 账户 ID `352cc14ef98508cccad2d4b3d86fb78b`。
