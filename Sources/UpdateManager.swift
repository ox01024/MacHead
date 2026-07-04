import Cocoa

/// 更新元数据模型，描述云端的最新版本信息
struct UpdateMetadata: Codable {
    let version: String
    let build: Int
    let pubDate: String
    let url: String
    let releaseNotes: String
}

final class UpdateManager {
    static let shared = UpdateManager()
    
    // Cloudflare R2 或是自定义子域名的 appcast.json 地址
    private let appcastURL = URL(string: "http://localhost:5173/appcast.json")!
    
    private var isChecking = false
    
    private init() {}
    
    /// 获取当前应用的版本号
    var currentVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    
    /// 获取当前应用的构建号
    var currentBuild: Int {
        if let buildStr = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           let buildInt = Int(buildStr) {
            return buildInt
        }
        return 1
    }
    
    /// 检查更新
    /// - Parameter silent: 是否为静默检查。静默检查下若无新版本则不弹窗打扰用户；若为手动检查，则无论有无新版均会弹出提示。
    func checkForUpdates(silent: Bool) {
        guard !isChecking else { return }
        isChecking = true
        
        let task = URLSession.shared.dataTask(with: appcastURL) { [weak self] data, response, error in
            guard let self = self else { return }
            self.isChecking = false
            
            if let error = error {
                print("OTA Check: Failed to fetch metadata: \(error)")
                if !silent {
                    self.showErrorAlert(message: "无法连接到更新服务器，请稍后重试。\n错误原因：\(error.localizedDescription)")
                }
                return
            }
            
            guard let data = data else {
                if !silent {
                    self.showErrorAlert(message: "服务器返回了空数据。")
                }
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let metadata = try decoder.decode(UpdateMetadata.self, from: data)
                
                let hasNewVersion = self.isNewer(
                    version: metadata.version,
                    build: metadata.build,
                    currentVersion: self.currentVersion,
                    currentBuild: self.currentBuild
                )
                
                if hasNewVersion {
                    self.showUpdateAlert(metadata: metadata)
                } else if !silent {
                    self.showUpToDateAlert()
                }
                
            } catch {
                print("OTA Check: Parsing error: \(error)")
                if !silent {
                    self.showErrorAlert(message: "解析更新数据失败。")
                }
            }
        }
        task.resume()
    }
    
    /// 版本号与构建号对比逻辑
    private func isNewer(version cloudVersion: String, build cloudBuild: Int, currentVersion: String, currentBuild: Int) -> Bool {
        // 利用 numeric 选项进行精准的 SemVer 比较
        let versionResult = cloudVersion.compare(currentVersion, options: .numeric)
        if versionResult == .orderedDescending {
            return true
        } else if versionResult == .orderedSame {
            return cloudBuild > currentBuild
        }
        return false
    }
    
    /// 发现新版本时的弹窗提示
    private func showUpdateAlert(metadata: UpdateMetadata) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "发现新版本 MacHead v\(metadata.version)"
            alert.informativeText = "发布日期: \(metadata.pubDate)\n\n更新日志:\n\(metadata.releaseNotes)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "下载更新 (打开浏览器)")
            alert.addButton(withTitle: "稍后提示我")
            
            // 提升 App 窗口前置
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: metadata.url) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    /// 当前已是最新版本时的弹窗
    private func showUpToDateAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "MacHead 已是最新版本"
            alert.informativeText = "您当前运行的版本是 v\(self.currentVersion) (Build \(self.currentBuild))，无需更新。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    
    /// 错误状态提示
    private func showErrorAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "检查更新失败"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
