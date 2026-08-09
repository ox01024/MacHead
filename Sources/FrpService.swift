import Foundation

extension Notification.Name {
    public static let frpStatusChanged = Notification.Name("com.waffle.MacHead.frpStatusChanged")
}

public struct FrpProxyRule: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var type: String // "tcp", "udp", "http", "https"
    public var localIP: String
    public var localPort: String
    public var remotePort: String
    public var customDomains: String
    public var subdomain: String
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        type: String = "tcp",
        localIP: String = "127.0.0.1",
        localPort: String,
        remotePort: String = "",
        customDomains: String = "",
        subdomain: String = ""
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.localIP = localIP
        self.localPort = localPort
        self.remotePort = remotePort
        self.customDomains = customDomains
        self.subdomain = subdomain
    }
}

public enum FrpStatus: Equatable {
    case stopped
    case connecting
    case connected
    case error(message: String)
    
    public var displayText: String {
        switch self {
        case .stopped:
            return "未启用 FRP 内网穿透"
        case .connecting:
            return "正在建立 FRP 穿透隧道..."
        case .connected:
            return "已成功建立 FRP 穿透隧道"
        case .error(let msg):
            return "穿透失败: \(msg)"
        }
    }
}

public final class FrpService {
    public static let shared = FrpService()
    
    private var process: Process?
    private var isServiceRunning = false
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    public private(set) var currentStatus: FrpStatus = .stopped {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .frpStatusChanged, object: self.currentStatus)
            }
        }
    }
    
    private init() {}
    
    public static func loadRules() -> [FrpProxyRule] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "frpProxyRulesJSON"),
           let rules = try? JSONDecoder().decode([FrpProxyRule].self, from: data),
           !rules.isEmpty {
            return rules
        }
        
        // Migration from single rule settings or fallback defaults
        let legacyName = defaults.string(forKey: "frpProxyName") ?? "machead-ssh"
        let legacyType = defaults.string(forKey: "frpProxyType") ?? "tcp"
        let legacyLocalIP = defaults.string(forKey: "frpLocalIP") ?? "127.0.0.1"
        let legacyLocalPort = defaults.string(forKey: "frpLocalPort") ?? "22"
        let legacyRemotePort = defaults.string(forKey: "frpRemotePort") ?? "6022"
        let legacyCustomDomains = defaults.string(forKey: "frpCustomDomains") ?? ""
        let legacySubdomain = defaults.string(forKey: "frpSubdomain") ?? ""
        
        let rule1 = FrpProxyRule(
            name: legacyName.isEmpty ? "machead-ssh" : legacyName,
            type: legacyType,
            localIP: legacyLocalIP.isEmpty ? "127.0.0.1" : legacyLocalIP,
            localPort: legacyLocalPort.isEmpty ? "22" : legacyLocalPort,
            remotePort: legacyRemotePort.isEmpty ? "6022" : legacyRemotePort,
            customDomains: legacyCustomDomains,
            subdomain: legacySubdomain
        )
        
        let rule2 = FrpProxyRule(
            name: "machead-web",
            type: "tcp",
            localIP: "127.0.0.1",
            localPort: "8080",
            remotePort: "8080"
        )
        
        let defaultRules = [rule1, rule2]
        saveRules(defaultRules)
        return defaultRules
    }
    
    public static func saveRules(_ rules: [FrpProxyRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "frpProxyRulesJSON")
        }
    }
    
    public func start() {
        guard !isServiceRunning else { return }
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "frpEnabled") else {
            currentStatus = .stopped
            killOrphanedProcesses()
            return
        }
        
        // Find binary path
        var binaryPath: String?
        if let customPath = defaults.string(forKey: "frpBinaryPath"), !customPath.isEmpty, FileManager.default.fileExists(atPath: customPath) {
            binaryPath = customPath
        } else {
            let binaryName = "frpc"
            let possiblePaths: [String?] = [
                Bundle.main.path(forResource: binaryName, ofType: nil),
                "/Applications/MacHead.app/Contents/Resources/\(binaryName)",
                "\(FileManager.default.currentDirectoryPath)/Resources/\(binaryName)",
                "\(Bundle.main.bundlePath)/Contents/Resources/\(binaryName)",
                "/opt/homebrew/bin/\(binaryName)",
                "/usr/local/bin/\(binaryName)",
                "\(NSHomeDirectory())/bin/\(binaryName)",
                "\(NSHomeDirectory())/.local/bin/\(binaryName)",
                "\(NSHomeDirectory())/.cargo/bin/\(binaryName)"
            ]
            
            for path in possiblePaths.compactMap({ $0 }) {
                if FileManager.default.fileExists(atPath: path) {
                    binaryPath = path
                    break
                }
            }
            
            if binaryPath == nil, let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
                for dir in pathEnv.split(separator: ":") {
                    let fullPath = "\(dir)/\(binaryName)"
                    if FileManager.default.fileExists(atPath: fullPath) {
                        binaryPath = fullPath
                        break
                    }
                }
            }
        }
        
        guard let path = binaryPath else {
            print("FrpService: Binary frpc not found")
            currentStatus = .error(message: "未找到 frpc 可执行文件 (可在配置中手动指定路径或执行 brew install frp)")
            return
        }
        
        let mode = defaults.string(forKey: "frpMode") ?? "quick"
        let configContent: String
        let isIniFormat: Bool
        
        if mode == "custom" {
            let customText = defaults.string(forKey: "frpCustomConfig") ?? ""
            if customText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                currentStatus = .error(message: "自定义配置内容为空")
                return
            }
            configContent = customText
            isIniFormat = customText.contains("[common]") || customText.contains("server_addr")
        } else {
            let serverAddr = defaults.string(forKey: "frpServerAddr") ?? ""
            let serverPort = defaults.string(forKey: "frpServerPort") ?? "7000"
            let token = defaults.string(forKey: "frpToken") ?? ""
            let rules = FrpService.loadRules()
            
            if serverAddr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                currentStatus = .error(message: "未配置 FRP 服务器地址")
                return
            }
            
            if rules.isEmpty {
                currentStatus = .error(message: "未配置任何代理隧道映射规则")
                return
            }
            
            let portInt = Int(serverPort) ?? 7000
            
            var lines = [
                "# Auto-generated by MacHead",
                "serverAddr = \"\(serverAddr)\"",
                "serverPort = \(portInt)"
            ]
            if !token.isEmpty {
                lines.append("auth.token = \"\(token)\"")
            }
            
            for (index, rule) in rules.enumerated() {
                lines.append("")
                lines.append("[[proxies]]")
                let ruleName = rule.name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                lines.append("name = \"\(ruleName.isEmpty ? "proxy-\(index+1)" : ruleName)\"")
                lines.append("type = \"\(rule.type.isEmpty ? "tcp" : rule.type)\"")
                lines.append("localIP = \"\(rule.localIP.isEmpty ? "127.0.0.1" : rule.localIP)\"")
                lines.append("localPort = \(Int(rule.localPort) ?? 22)")
                
                if rule.type == "tcp" || rule.type == "udp" {
                    if let rPort = Int(rule.remotePort), rPort > 0 {
                        lines.append("remotePort = \(rPort)")
                    }
                } else if rule.type == "http" || rule.type == "https" {
                    if !rule.customDomains.isEmpty {
                        lines.append("customDomains = [\"\(rule.customDomains)\"]")
                    }
                    if !rule.subdomain.isEmpty {
                        lines.append("subdomain = \"\(rule.subdomain)\"")
                    }
                }
            }
            
            configContent = lines.joined(separator: "\n")
            isIniFormat = false
        }
        
        let filename = isIniFormat ? "machead_frpc.ini" : "machead_frpc.toml"
        let configPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)
        do {
            try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        } catch {
            print("FrpService: Failed to write config file - \(error.localizedDescription)")
            currentStatus = .error(message: "配置文件写入失败: \(error.localizedDescription)")
            return
        }
        
        currentStatus = .connecting
        
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
            print("FrpService: frpc process terminated with status \(proc.terminationStatus)")
            self?.isServiceRunning = false
            
            DispatchQueue.main.async {
                if self?.currentStatus == .connecting {
                    self?.currentStatus = .error(message: "进程异常退出 (Code \(proc.terminationStatus))")
                }
            }
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                let stillEnabled = UserDefaults.standard.bool(forKey: "frpEnabled")
                if stillEnabled && !self.isServiceRunning {
                    print("FrpService: Attempting auto-restart...")
                    self.start()
                }
            }
        }
        
        do {
            try newProcess.run()
            self.process = newProcess
            self.isServiceRunning = true
            print("FrpService: Successfully started frpc with config \(configPath)")
        } catch {
            print("FrpService: Failed to launch frpc process - \(error.localizedDescription)")
            currentStatus = .error(message: "启动失败: \(error.localizedDescription)")
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
        if lower.contains("start proxy success") || lower.contains("login to server success") || lower.contains("proxy added") {
            currentStatus = .connected
        } else if lower.contains("authorization failed") || lower.contains("token invalid") || lower.contains("token error") {
            currentStatus = .error(message: "鉴权失败 (Token 错误)")
        } else if lower.contains("connection refused") || lower.contains("connect to server error") || lower.contains("i/o timeout") || lower.contains("dial tcp") {
            currentStatus = .error(message: "无法连接服务端 (请检查服务器 IP 和端口)")
        } else if lower.contains("already exists") {
            currentStatus = .error(message: "代理名称已被占用")
        } else if lower.contains("port unavailable") || lower.contains("port already in use") {
            currentStatus = .error(message: "远程端口不可用或已被占用")
        }
    }
    
    public func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        print("FrpService: Stopping frpc...")
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
        task.arguments = ["frpc"]
        try? task.run()
        
        let tmpToml = (NSTemporaryDirectory() as NSString).appendingPathComponent("machead_frpc.toml")
        let tmpIni = (NSTemporaryDirectory() as NSString).appendingPathComponent("machead_frpc.ini")
        try? FileManager.default.removeItem(atPath: tmpToml)
        try? FileManager.default.removeItem(atPath: tmpIni)
    }
    
    public func isRunning() -> Bool {
        return isServiceRunning && (process?.isRunning ?? false)
    }
}
