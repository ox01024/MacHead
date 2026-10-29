import Foundation

extension Notification.Name {
    public static let cloudflareStatusChanged = Notification.Name("com.waffle.MacHead.cloudflareStatusChanged")
}

public enum CloudflareStatus: Equatable {
    case stopped
    case connecting
    case connected
    case error(message: String)

    public var displayText: String {
        switch self {
        case .stopped:
            return L("未启用 Cloudflare Tunnel 穿透", "Cloudflare Tunnel is disabled")
        case .connecting:
            return L("正在建立 Cloudflare 穿透隧道...", "Connecting to Cloudflare Tunnel...")
        case .connected:
            return L("已成功建立 Cloudflare 穿透隧道", "Connected to Cloudflare Tunnel")
        case .error(let msg):
            return L("穿透失败: \(msg)", "Tunnel failed: \(msg)")
        }
    }
}

public final class CloudflareService {
    public static let shared = CloudflareService()

    private var process: Process?
    private var isServiceRunning = false
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    public private(set) var currentStatus: CloudflareStatus = .stopped {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cloudflareStatusChanged, object: self.currentStatus)
            }
        }
    }

    private init() {}

    public func findBinaryPath() -> String? {
        let defaults = UserDefaults.standard
        if let customPath = defaults.string(forKey: "cloudflareBinaryPath"), !customPath.isEmpty, FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }

        let binaryName = "cloudflared"
        let possiblePaths: [String?] = [
            Bundle.main.path(forResource: binaryName, ofType: nil),
            "/Applications/MacHead.app/Contents/Resources/\(binaryName)",
            "\(FileManager.default.currentDirectoryPath)/Resources/\(binaryName)",
            "\(Bundle.main.bundlePath)/Contents/Resources/\(binaryName)",
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
            "/opt/homebrew/opt/cloudflared/bin/\(binaryName)",
            "/usr/local/opt/cloudflared/bin/\(binaryName)",
            "\(NSHomeDirectory())/bin/\(binaryName)",
            "\(NSHomeDirectory())/.local/bin/\(binaryName)"
        ]

        for path in possiblePaths.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let fullPath = "\(dir)/\(binaryName)"
                if FileManager.default.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
        }

        return nil
    }

    public func start() {
        guard !isServiceRunning else { return }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "cloudflareEnabled") else {
            currentStatus = .stopped
            killOrphanedProcesses()
            return
        }

        guard let path = findBinaryPath() else {
            print("CloudflareService: Binary cloudflared not found")
            currentStatus = .error(message: L(
                "未找到 cloudflared 可执行文件 (请安装 brew install cloudflared 或手动指定路径)",
                "cloudflared binary not found (run 'brew install cloudflared' or specify path)"
            ))
            return
        }

        let token = (defaults.string(forKey: "cloudflareToken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            currentStatus = .error(message: L("未配置 Cloudflare Tunnel Token", "Cloudflare Tunnel Token is empty"))
            return
        }

        currentStatus = .connecting

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: path)
        newProcess.arguments = ["tunnel", "--no-autoupdate", "run", "--token", token]

        let outPipe = Pipe()
        let errPipe = Pipe()
        newProcess.standardOutput = outPipe
        newProcess.standardError = errPipe
        self.outputPipe = outPipe
        self.errorPipe = errPipe

        setupPipeObserver(outPipe)
        setupPipeObserver(errPipe)

        newProcess.terminationHandler = { [weak self] proc in
            print("CloudflareService: cloudflared process terminated with status \(proc.terminationStatus)")
            self?.isServiceRunning = false

            DispatchQueue.main.async {
                if self?.currentStatus == .connecting {
                    self?.currentStatus = .error(message: L(
                        "进程异常退出 (Code \(proc.terminationStatus))",
                        "Process exited unexpectedly (Code \(proc.terminationStatus))"
                    ))
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                let stillEnabled = UserDefaults.standard.bool(forKey: "cloudflareEnabled")
                if stillEnabled && !self.isServiceRunning {
                    print("CloudflareService: Attempting auto-restart...")
                    self.start()
                }
            }
        }

        do {
            try newProcess.run()
            self.process = newProcess
            self.isServiceRunning = true
            print("CloudflareService: Successfully started cloudflared with token")
        } catch {
            print("CloudflareService: Failed to launch cloudflared process - \(error.localizedDescription)")
            currentStatus = .error(message: L(
                "启动失败: \(error.localizedDescription)",
                "Failed to start: \(error.localizedDescription)"
            ))
        }
    }

    private func setupPipeObserver(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.parseLogLine(line)
        }
    }

    private func parseLogLine(_ line: String) {
        let lower = line.lowercased()
        if lower.contains("registered tunnel connection") || lower.contains("connection registered") || lower.contains("infra connection registered") || lower.contains("connected to ") || lower.contains("route propagating") {
            currentStatus = .connected
        } else if lower.contains("token is invalid") || lower.contains("invalid tunnel token") || lower.contains("cannot decode token") || lower.contains("invalid token") {
            currentStatus = .error(message: L("Tunnel Token 格式无效或已失效", "Invalid or expired Tunnel Token"))
        } else if lower.contains("failed to create tunnel") || lower.contains("dial tcp") || lower.contains("connection refused") || lower.contains("i/o timeout") {
            currentStatus = .error(message: L("无法连接 Cloudflare 边缘节点 (网络异常)", "Cannot reach Cloudflare edge network"))
        }
    }

    public func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        print("CloudflareService: Stopping cloudflared...")
        let procToStop = self.process
        self.process = nil
        self.isServiceRunning = false
        self.currentStatus = .stopped

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            procToStop?.terminationHandler = nil
            if let proc = procToStop, proc.isRunning {
                proc.terminate()
            }
            self?.killOrphanedProcesses()
        }
    }

    private func killOrphanedProcesses() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["cloudflared"]
        try? task.run()
    }

    public func isRunning() -> Bool {
        return isServiceRunning && (process?.isRunning ?? false)
    }

    public func testConnection(token: String, completion: @escaping (Bool, String) -> Void) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            completion(false, L("Token 不能为空", "Token cannot be empty"))
            return
        }

        guard let path = findBinaryPath() else {
            completion(false, L("未找到 cloudflared 可执行文件", "cloudflared binary not found"))
            return
        }

        let testProcess = Process()
        testProcess.executableURL = URL(fileURLWithPath: path)
        testProcess.arguments = ["tunnel", "--no-autoupdate", "run", "--token", cleanToken]

        let pipe = Pipe()
        testProcess.standardError = pipe
        testProcess.standardOutput = pipe

        var finished = false
        var resultOutput = ""
        let lock = NSLock()

        func finish(success: Bool, message: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            pipe.fileHandleForReading.readabilityHandler = nil
            if testProcess.isRunning {
                testProcess.terminate()
            }
            DispatchQueue.main.async {
                completion(success, message)
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            resultOutput += line
            let lower = line.lowercased()
            lock.unlock()

            if lower.contains("registered tunnel connection") || lower.contains("connection registered") || lower.contains("infra connection registered") || lower.contains("connected to ") {
                finish(success: true, message: L("连通性测试成功：已成功连接至 Cloudflare 边缘节点", "Connection test passed: Connected to Cloudflare edge"))
            } else if lower.contains("token is invalid") || lower.contains("invalid tunnel token") || lower.contains("cannot decode token") || lower.contains("invalid token") {
                finish(success: false, message: L("测试失败：Tunnel Token 格式无效或已失效", "Test failed: Invalid or expired Tunnel Token"))
            } else if lower.contains("connection refused") || lower.contains("i/o timeout") {
                finish(success: false, message: L("测试失败：连接 Cloudflare 节点超时", "Test failed: Connection to Cloudflare timed out"))
            }
        }

        do {
            try testProcess.run()
        } catch {
            completion(false, L("启动测试失败: \(error.localizedDescription)", "Failed to launch test: \(error.localizedDescription)"))
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            lock.lock()
            let isDone = finished
            lock.unlock()
            if !isDone {
                if resultOutput.lowercased().contains("starting tunnel") || resultOutput.lowercased().contains("environment is healthy") {
                    finish(success: true, message: L("连通性测试成功：环境健康，隧道就绪", "Connection test passed: Tunnel environment is healthy"))
                } else {
                    finish(success: false, message: L("测试超时：未在 5 秒内收到 Cloudflare 握手响应", "Test timed out: No Cloudflare handshake within 5 seconds"))
                }
            }
        }
    }
}
