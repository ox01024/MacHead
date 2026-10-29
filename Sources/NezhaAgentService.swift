import Foundation

extension Notification.Name {
    public static let nezhaStatusChanged = Notification.Name("com.waffle.MacHead.nezhaStatusChanged")
}

public enum NezhaStatus: Equatable {
    case stopped
    case connecting
    case connected
    case error(message: String)
    
    public var displayText: String {
        switch self {
        case .stopped:
            return L("未启用哪吒监控", "Nezha Monitoring is disabled")
        case .connecting:
            return L("正在建立连接并与服务端握手...", "Connecting to Nezha server...")
        case .connected:
            return L("已成功连接，正在进行实时心跳通信", "Connected — sending real-time heartbeat")
        case .error(let msg):
            return L("连接失败: \(msg)", "Connection failed: \(msg)")
        }
    }
}

public final class NezhaAgentService {
    public static let shared = NezhaAgentService()
    
    private var process: Process?
    private var isServiceRunning = false
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    public private(set) var currentStatus: NezhaStatus = .stopped {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .nezhaStatusChanged, object: self.currentStatus)
            }
        }
    }
    
    private init() {}
    
    public func start() {
        guard !isServiceRunning else { return }
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "nezhaEnabled") else {
            currentStatus = .stopped
            killOrphanedProcesses()
            return
        }
        
        guard let server = defaults.string(forKey: "nezhaServer"), !server.isEmpty,
              let secret = defaults.string(forKey: "nezhaSecret"), !secret.isEmpty else {
            print("NezhaAgentService: Missing server or secret configuration")
            currentStatus = .error(message: L("未配置面板地址或连接密钥", "Nezha server address or secret is empty"))
            return
        }

        // Find binary path
        let binaryName = "nezha-agent"
        var binaryPath = Bundle.main.path(forResource: binaryName, ofType: nil)

        // Fallback for command line or sandbox environments
        if binaryPath == nil {
            let possiblePaths = [
                "/Applications/MacHead.app/Contents/Resources/\(binaryName)",
                "\(FileManager.default.currentDirectoryPath)/Resources/\(binaryName)",
                "\(Bundle.main.bundlePath)/Contents/Resources/\(binaryName)"
            ]
            for path in possiblePaths {
                if FileManager.default.fileExists(atPath: path) {
                    binaryPath = path
                    break
                }
            }
        }

        guard let path = binaryPath else {
            print("NezhaAgentService: Binary \(binaryName) not found in resources")
            currentStatus = .error(message: L("未找到 nezha-agent 可执行文件", "nezha-agent binary not found"))
            return
        }

        currentStatus = .connecting

        let isTls = defaults.bool(forKey: "nezhaTls")
        let configContent = """
        client_secret: "\(secret)"
        debug: true
        disable_auto_update: true
        server: "\(server)"
        tls: \(isTls ? "true" : "false")
        """

        let configPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("machead_nezha.yml")
        do {
            try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        } catch {
            print("NezhaAgentService: Failed to write config file - \(error.localizedDescription)")
            currentStatus = .error(message: L(
                "配置文件写入失败: \(error.localizedDescription)",
                "Failed to write config file: \(error.localizedDescription)"
            ))
            return
        }

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: path)
        newProcess.arguments = ["-c", configPath]

        let outPipe = Pipe()
        let errPipe = Pipe()
        newProcess.standardOutput = outPipe
        newProcess.standardError = errPipe
        self.outputPipe = outPipe
        self.errorPipe = errPipe

        setupPipeObserver(outPipe)
        setupPipeObserver(errPipe)

        newProcess.terminationHandler = { [weak self] proc in
            print("NezhaAgentService: nezha-agent process terminated with status \(proc.terminationStatus)")
            self?.isServiceRunning = false

            DispatchQueue.main.async {
                if self?.currentStatus == .connecting {
                    self?.currentStatus = .error(message: L(
                        "进程异常退出 (Code \(proc.terminationStatus))",
                        "Process exited unexpectedly (Code \(proc.terminationStatus))"
                    ))
                }
            }

            // Auto restart if it was supposed to be running
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                let stillEnabled = UserDefaults.standard.bool(forKey: "nezhaEnabled")
                if stillEnabled && !self.isServiceRunning {
                    print("NezhaAgentService: Attempting auto-restart...")
                    self.start()
                }
            }
        }

        do {
            try newProcess.run()
            self.process = newProcess
            self.isServiceRunning = true
            print("NezhaAgentService: Successfully started nezha-agent with server \(server)")
        } catch {
            print("NezhaAgentService: Failed to launch nezha-agent process - \(error.localizedDescription)")
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
        if line.contains("Connection to") && line.contains("established") || line.contains("正在更新本地缓存IP信息") {
            currentStatus = .connected
        } else if line.contains("missing port in address") {
            currentStatus = .error(message: L(
                "地址缺少端口号 (请使用 host:port 格式，如 104.223.55.31:8008)",
                "Missing port in server address (use host:port, e.g., 104.223.55.31:8008)"
            ))
        } else if line.contains("authentication handshake failed") || line.contains("error reading server preface: EOF") {
            currentStatus = .error(message: L(
                "认证握手失败 (请检查 Secret 密钥或端口 8008/5555 是否对应)",
                "Authentication handshake failed (check Secret or port 8008/5555)"
            ))
        } else if line.contains("connection refused") {
            currentStatus = .error(message: L(
                "服务器拒绝连接 (请检查服务器 IP、端口及防火墙设置)",
                "Connection refused (check server IP, port, and firewall)"
            ))
        }
    }
    
    public func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        print("NezhaAgentService: Stopping nezha-agent...")
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
        task.arguments = ["nezha-agent"]
        try? task.run()
        
        let tmpDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("nezha-agent")
        try? FileManager.default.removeItem(atPath: tmpDir)
    }
    
    public func isRunning() -> Bool {
        return isServiceRunning && (process?.isRunning ?? false)
    }
}
