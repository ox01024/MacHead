import Cocoa

/// 更新元数据模型，描述云端的最新版本信息
struct UpdateMetadata: Codable {
    let version: String
    let build: Int
    let pubDate: String
    let url: String
    let releaseNotes: String
}

final class UpdateManager: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateManager()
    
    // Cloudflare R2 或是自定义子域名的 appcast.json 地址
    private let appcastURL = URL(string: "http://localhost:5173/appcast.json")!
    
    private var isChecking = false
    private var activeMetadata: UpdateMetadata?
    private var downloadTask: URLSessionDownloadTask?
    
    private var progressAlert: NSAlert?
    private var progressIndicator: NSProgressIndicator?
    
    private override init() {
        super.init()
    }
    
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
    func checkForUpdates(silent: Bool) {
        guard !isChecking else { return }
        isChecking = true
        
        let task = URLSession.shared.dataTask(with: appcastURL) { [weak self] data, response, error in
            guard let self = self else { return }
            self.isChecking = false
            
            if let error = error {
                print("OTA Check: Failed to fetch metadata: \(error)")
                if !silent {
                    self.showErrorAlert(message: "无法连接到更新服务器，请稍后重试。\n原因：\(error.localizedDescription)")
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
    
    private func isNewer(version cloudVersion: String, build cloudBuild: Int, currentVersion: String, currentBuild: Int) -> Bool {
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
            alert.addButton(withTitle: "立即更新")
            alert.addButton(withTitle: "稍后提示我")
            
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.startDownload(metadata: metadata)
            }
        }
    }
    
    /// 启动应用内静默下载
    private func startDownload(metadata: UpdateMetadata) {
        guard let url = URL(string: metadata.url) else { return }
        self.activeMetadata = metadata
        
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.downloadTask = session.downloadTask(with: url)
        self.downloadTask?.resume()
        
        // 显示下载进度条弹窗
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "正在下载 MacHead v\(metadata.version)..."
            alert.informativeText = "正在从安全服务器下载最新的 DMG 安装包，请稍候。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "取消")
            
            let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
            indicator.isIndeterminate = false
            indicator.minValue = 0
            indicator.maxValue = 100
            indicator.doubleValue = 0
            alert.accessoryView = indicator
            
            self.progressAlert = alert
            self.progressIndicator = indicator
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                print("OTA Download: User canceled the download.")
                self.downloadTask?.cancel()
            }
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0
        
        DispatchQueue.main.async {
            self.progressIndicator?.doubleValue = percent
            self.progressAlert?.informativeText = String(format: "已下载: %.1f%%", percent)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 关闭进度条 Modal 弹窗
        DispatchQueue.main.async {
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
            self.progressAlert?.window.close()
        }
        
        // 将下载完的临时文件拷贝到安全的临时存储路径
        let tempDir = NSTemporaryDirectory()
        let destinationURL = URL(fileURLWithPath: tempDir).appendingPathComponent("MacHeadUpdate.dmg")
        
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destinationURL)
        
        do {
            try fileManager.moveItem(at: location, to: destinationURL)
            // 开始执行挂载覆盖安装
            self.installUpdate(localURL: destinationURL)
        } catch {
            self.handleInstallationFailure(reason: "保存更新包失败：\(error.localizedDescription)")
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            // 如果下载出错并且不是用户手动取消
            if let error = error {
                let nsError = error as NSError
                if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
                    NSApp.stopModal(withCode: .alertSecondButtonReturn)
                    self.progressAlert?.window.close()
                    self.handleInstallationFailure(reason: "网络下载失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Mounting & Coping installation
    
    private func installUpdate(localURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let mountPoint = "/tmp/MacHeadMount"
            let fileManager = FileManager.default
            
            // 确保挂载目录存在
            if !fileManager.fileExists(atPath: mountPoint) {
                try? fileManager.createDirectory(atPath: mountPoint, withIntermediateDirectories: true, attributes: nil)
            }
            
            print("OTA Install: Mounting DMG...")
            let (mountStatus, mountOutput) = self.runShellCommand("/usr/bin/hdiutil", arguments: [
                "mount", "-nobrowse", "-mountpoint", mountPoint, localURL.path
            ])
            
            guard mountStatus == 0 else {
                self.handleInstallationFailure(reason: "挂载 DMG 失败 (code: \(mountStatus)): \(mountOutput)")
                return
            }
            
            let mountedAppPath = "\(mountPoint)/MacHead.app"
            guard fileManager.fileExists(atPath: mountedAppPath) else {
                self.cleanupMount(mountPoint: mountPoint)
                self.handleInstallationFailure(reason: "DMG 中未找到 MacHead.app 应用程序包。")
                return
            }
            
            let targetAppPath = "/Applications/MacHead.app"
            print("OTA Install: Replacing app bundle...")
            
            do {
                if fileManager.fileExists(atPath: targetAppPath) {
                    try fileManager.removeItem(atPath: targetAppPath)
                }
                try fileManager.copyItem(atPath: mountedAppPath, toPath: targetAppPath)
            } catch {
                self.cleanupMount(mountPoint: mountPoint)
                self.handleInstallationFailure(reason: "文件覆盖失败：\(error.localizedDescription)")
                return
            }
            
            // 卸载临时磁盘并删除 DMG
            self.cleanupMount(mountPoint: mountPoint)
            try? fileManager.removeItem(at: localURL)
            
            print("OTA Install: Finished successfully!")
            self.promptForRestart()
        }
    }
    
    private func cleanupMount(mountPoint: String) {
        self.runShellCommand("/usr/bin/hdiutil", arguments: ["detach", "-force", mountPoint])
        try? FileManager.default.removeItem(atPath: mountPoint)
    }
    
    /// 执行系统底层命令的管道工具
    @discardableResult
    private func runShellCommand(_ command: String, arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.launchPath = command
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.launch()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
    
    private func handleInstallationFailure(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let alert = NSAlert()
            alert.messageText = "更新安装失败"
            alert.informativeText = "\(reason)\n\n系统将自动为您打开浏览器下载，请手动下载 DMG 拖拽覆盖安装。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            
            // 降级兜底方案：浏览器打开下载
            if let metadata = self.activeMetadata, let url = URL(string: metadata.url) {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    private func promptForRestart() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "更新成功！"
            alert.informativeText = "最新版 MacHead 已成功部署。是否立即重启应用？"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "立即重启")
            alert.addButton(withTitle: "稍后")
            
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let appURL = URL(fileURLWithPath: "/Applications/MacHead.app")
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                    if let error = error {
                        print("Failed to relaunch application: \(error)")
                    }
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
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
