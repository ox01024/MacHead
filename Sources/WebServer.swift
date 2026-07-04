import Foundation
import Network
import SystemConfiguration

final class WebServer {
    static let shared = WebServer()
    
    private var listener: NWListener?
    private var lastCPUInfo: processor_info_array_t?
    private var lastCPUInfoCount: mach_msg_type_number_t = 0
    
    private init() {}
    
    func start() {
        let enableWebServer = UserDefaults.standard.bool(forKey: "EnableWebServer")
        guard enableWebServer else { return }
        guard listener == nil else { return }
        
        guard let port = NWEndpoint.Port(rawValue: 8080) else { return }
        
        do {
            let newListener = try NWListener(using: .tcp, on: port)
            self.listener = newListener
            
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("MacHead: Web 服务器启动就绪，端口: 8080")
                case .failed(let error):
                    NSLog("MacHead: Web 服务器失败: %@", error.localizedDescription)
                    self.stop()
                default:
                    break
                }
            }
            
            newListener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                self.handleConnection(connection)
            }
            
            newListener.start(queue: .main)
        } catch {
            NSLog("MacHead: 无法启动 Web 服务器: %@", error.localizedDescription)
        }
    }
    
    func stop() {
        if let activeListener = listener {
            activeListener.cancel()
            listener = nil
            NSLog("MacHead: Web 服务器已关闭")
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, context, isComplete, error in
            guard let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            let requestStr = String(decoding: data, as: UTF8.self)
            let lines = requestStr.components(separatedBy: "\r\n")
            guard !lines.isEmpty else {
                connection.cancel()
                return
            }
            
            let firstLineParts = lines[0].components(separatedBy: " ")
            guard firstLineParts.count >= 2 else {
                connection.cancel()
                return
            }
            
            let method = firstLineParts[0]
            let path = firstLineParts[1]
            
            // 验证 HTTP Basic Auth 认证
            if !self.verifyBasicAuth(headers: lines) {
                self.sendUnauthorizedResponse(connection: connection)
                return
            }
            
            self.routeRequest(method: method, path: path, connection: connection)
        }
    }
    
    private func verifyBasicAuth(headers: [String]) -> Bool {
        let password = UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
        guard !password.isEmpty else { return true }
        
        for line in headers {
            if let range = line.range(of: "Authorization:\\s*Basic\\s+", options: [.regularExpression, .caseInsensitive]) {
                let base64Part = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let decodedData = Data(base64Encoded: base64Part),
                   let credentials = String(data: decodedData, encoding: .utf8) {
                    let credParts = credentials.components(separatedBy: ":")
                    if credParts.count >= 2 {
                        let enteredPassword = credParts[1]
                        if enteredPassword == password {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }
    
    private func sendUnauthorizedResponse(connection: NWConnection) {
        let responseHeader = [
            "HTTP/1.1 401 Unauthorized",
            "WWW-Authenticate: Basic realm=\"MacHead Secure Dashboard\"",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: 16",
            "Connection: close",
            "",
            "401 Unauthorized"
        ].joined(separator: "\r\n")
        
        let responseData = responseHeader.data(using: .utf8)!
        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func routeRequest(method: String, path: String, connection: NWConnection) {
        if method == "GET" && path == "/" {
            sendResponse(html: getDashboardHTML(), connection: connection)
        } else if method == "GET" && path == "/api/status" {
            sendResponse(json: getStatusJSON(), connection: connection)
        } else if method == "POST" && path == "/api/toggle-headless" {
            DispatchQueue.main.async {
                if HeadlessModeController.shared.isHeadlessModeEnabled {
                    HeadlessModeController.shared.disableHeadlessMode()
                } else {
                    HeadlessModeController.shared.enableHeadlessMode()
                }
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-trackpad" {
            DispatchQueue.main.async {
                let key = "DisableTrackpadWhenExternalMouseConnected"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-keyboard-headless" {
            DispatchQueue.main.async {
                let key = "DisableKeyboardAndTrackpadInHeadlessMode"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                InputDeviceManager.shared.evaluateTrackpadAndKeyboardState()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-microphone" {
            DispatchQueue.main.async {
                let key = "MuteMicrophoneInHeadlessMode"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                if HeadlessModeController.shared.isHeadlessModeEnabled {
                    if val {
                        MediaDeviceManager.shared.muteBuiltInMicrophone()
                    } else {
                        MediaDeviceManager.shared.forceUnmute()
                    }
                }
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-sleep" {
            DispatchQueue.main.async {
                let key = "PreventIdleSleep"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                HeadlessModeController.shared.evaluatePowerAssertion()
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-exit-on-disconnect" {
            DispatchQueue.main.async {
                let key = "AutoExitHeadlessOnDisconnect"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else if method == "POST" && path == "/api/toggle-restore-on-connect" {
            DispatchQueue.main.async {
                let key = "AutoRestoreHeadlessOnConnect"
                let val = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                NotificationCenter.default.post(name: .headlessModeStateChanged, object: nil)
                self.sendResponse(json: self.getStatusJSON(), connection: connection)
            }
        } else {
            sendResponse(statusCode: 404, statusText: "Not Found", content: "Page Not Found".data(using: .utf8)!, contentType: "text/plain", connection: connection)
        }
    }
    
    private func sendResponse(html: String, connection: NWConnection) {
        let content = html.data(using: .utf8)!
        sendResponse(statusCode: 200, statusText: "OK", content: content, contentType: "text/html; charset=utf-8", connection: connection)
    }
    
    private func sendResponse(json: String, connection: NWConnection) {
        let content = json.data(using: .utf8)!
        sendResponse(statusCode: 200, statusText: "OK", content: content, contentType: "application/json", connection: connection)
    }
    
    private func sendResponse(statusCode: Int, statusText: String, content: Data, contentType: String, connection: NWConnection) {
        let headers = [
            "HTTP/1.1 \(statusCode) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(content.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        
        var responseData = headers.data(using: .utf8)!
        responseData.append(content)
        
        connection.send(content: responseData, completion: .contentProcessed({ error in
            connection.cancel()
        }))
    }
    
    private func getStatusJSON() -> String {
        let cpu = getCPUUsage()
        let ram = getMemoryUsage()
        
        return """
        {
          "headlessModeEnabled": \(HeadlessModeController.shared.isHeadlessModeEnabled),
          "preventIdleSleep": \(UserDefaults.standard.bool(forKey: "PreventIdleSleep")),
          "trackpadDisabled": \(UserDefaults.standard.bool(forKey: "DisableTrackpadWhenExternalMouseConnected")),
          "keyboardAndTrackpadDisabledInHeadless": \(UserDefaults.standard.bool(forKey: "DisableKeyboardAndTrackpadInHeadlessMode")),
          "microphoneMuted": \(MediaDeviceManager.shared.isMuted),
          "batteryCapacity": \(BatteryManager.shared.currentCapacity),
          "isCharging": \(BatteryManager.shared.isCharging),
          "powerState": "\(BatteryManager.shared.powerState)",
          "cpuUsage": \(cpu),
          "memoryUsage": \(ram),
          "autoExitHeadlessOnDisconnect": \(UserDefaults.standard.bool(forKey: "AutoExitHeadlessOnDisconnect")),
          "autoRestoreHeadlessOnConnect": \(UserDefaults.standard.bool(forKey: "AutoRestoreHeadlessOnConnect"))
        }
        """
    }
    
    func getLocalIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        guard let firstAddr = ifaddr else { return address }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: hostname)
                        break
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
    
    private func getMemoryUsage() -> Double {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 {
            return Double(100 - level)
        }
        return 0.0
    }
    
    private func getCPUUsage() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return 0.0 }
        
        defer {
            if let last = lastCPUInfo {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: last), vm_size_t(lastCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
            }
            lastCPUInfo = cpuInfo
            lastCPUInfoCount = numCPUInfo
        }
        
        guard let lastInfo = lastCPUInfo else { return 0.0 }
        
        var totalInUse: Int32 = 0
        var totalTotal: Int32 = 0
        
        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            let lastBase = i * Int(CPU_STATE_MAX)
            
            let user = cpuInfo[base + Int(CPU_STATE_USER)] - lastInfo[lastBase + Int(CPU_STATE_USER)]
            let system = cpuInfo[base + Int(CPU_STATE_SYSTEM)] - lastInfo[lastBase + Int(CPU_STATE_SYSTEM)]
            let idle = cpuInfo[base + Int(CPU_STATE_IDLE)] - lastInfo[lastBase + Int(CPU_STATE_IDLE)]
            let nice = cpuInfo[base + Int(CPU_STATE_NICE)] - lastInfo[lastBase + Int(CPU_STATE_NICE)]
            
            let inUse = user + system + nice
            let total = inUse + idle
            
            totalInUse += inUse
            totalTotal += total
        }
        
        guard totalTotal > 0 else { return 0.0 }
        return (Double(totalInUse) / Double(totalTotal)) * 100.0
    }
    
    private func getDashboardHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>MacHead 控制面板</title>
            <link rel="preconnect" href="https://fonts.googleapis.com">
            <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
            <link href="https://fonts.googleapis.com/css2?family=EB+Garamond:ital,wght@0,400..800;1,400..800&family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
            <style>
                :root {
                    /* Warm Light Theme */
                    --bg-color: #fbf9fa;
                    --text-color: #26251e;
                    --text-muted: rgba(38, 37, 30, 0.55);
                    --card-bg: #ffffff;
                    --card-border: rgba(38, 37, 30, 0.08);
                    --card-border-hover: rgba(38, 37, 30, 0.16);
                    --card-shadow: 0 8px 30px rgba(38, 37, 30, 0.03);
                    --input-bg: #f3f1f2;
                    --toggle-dot-active: #fbf9fa;
                    
                    /* Fonts */
                    --font-serif: 'EB Garamond', Georgia, serif;
                    --font-sans: 'Inter', system-ui, sans-serif;
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        /* Warm Dark Theme */
                        --bg-color: #14120b;
                        --text-color: #edecec;
                        --text-muted: rgba(237, 236, 236, 0.55);
                        --card-bg: #1c1b14;
                        --card-border: rgba(237, 236, 236, 0.08);
                        --card-border-hover: rgba(237, 236, 236, 0.16);
                        --card-shadow: 0 8px 30px rgba(0, 0, 0, 0.15);
                        --input-bg: #0b0a05;
                        --toggle-dot-active: #14120b;
                    }
                }

                body[data-theme="light"] {
                    --bg-color: #fbf9fa;
                    --text-color: #26251e;
                    --text-muted: rgba(38, 37, 30, 0.55);
                    --card-bg: #ffffff;
                    --card-border: rgba(38, 37, 30, 0.08);
                    --card-border-hover: rgba(38, 37, 30, 0.16);
                    --card-shadow: 0 8px 30px rgba(38, 37, 30, 0.03);
                    --input-bg: #f3f1f2;
                    --toggle-dot-active: #fbf9fa;
                }

                body[data-theme="dark"] {
                    --bg-color: #14120b;
                    --text-color: #edecec;
                    --text-muted: rgba(237, 236, 236, 0.55);
                    --card-bg: #1c1b14;
                    --card-border: rgba(237, 236, 236, 0.08);
                    --card-border-hover: rgba(237, 236, 236, 0.16);
                    --card-shadow: 0 8px 30px rgba(0, 0, 0, 0.15);
                    --input-bg: #0b0a05;
                    --toggle-dot-active: #14120b;
                }

                * { box-sizing: border-box; margin: 0; padding: 0; }
                
                body {
                    font-family: var(--font-sans);
                    background-color: var(--bg-color);
                    color: var(--text-color);
                    min-height: 100vh;
                    padding: 60px 24px;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    transition: background-color 0.3s, color 0.3s;
                }
                
                .container {
                    width: 100%;
                    max-width: 800px;
                }
                
                header {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    margin-bottom: 40px;
                    width: 100%;
                    border-bottom: 1px solid var(--card-border);
                    padding-bottom: 16px;
                }
                
                header h1 {
                    font-family: var(--font-serif);
                    font-size: 26px;
                    font-weight: 400;
                    color: var(--text-color);
                }
                
                .grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
                    gap: 20px;
                    margin-bottom: 20px;
                }
                
                .card {
                    background: var(--card-bg);
                    border: 1px solid var(--card-border);
                    border-radius: 4px;
                    padding: 24px;
                    box-shadow: var(--card-shadow);
                    transition: border-color 0.15s ease, transform 0.15s ease;
                }
                
                .card:hover {
                    border-color: var(--card-border-hover);
                }
                
                .card-title {
                    font-family: var(--font-serif);
                    font-size: 16px;
                    font-weight: 400;
                    color: var(--text-color);
                    margin-bottom: 16px;
                }
                
                .card-value {
                    font-family: var(--font-sans);
                    font-size: 28px;
                    font-weight: 500;
                    color: var(--text-color);
                    display: flex;
                    align-items: center;
                    gap: 8px;
                }
                
                .control-row {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    padding: 16px 0;
                    border-bottom: 1px solid var(--card-border);
                }
                
                .control-row:last-child {
                    border-bottom: none;
                }
                
                .control-label {
                    font-weight: 500;
                    font-size: 14.5px;
                }
                
                .control-desc {
                    font-size: 12px;
                    color: var(--text-muted);
                    margin-top: 4px;
                }
                
                .status-dot {
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    display: inline-block;
                }
                
                .status-dot.active {
                    background-color: #42b883;
                }
                
                .status-dot.inactive {
                    background-color: #ff5252;
                }
                
                /* Minimal Switch Slider */
                .switch {
                    position: relative;
                    display: inline-block;
                    width: 32px;
                    height: 18px;
                }
                
                .switch input {
                    opacity: 0;
                    width: 0;
                    height: 0;
                }
                
                .slider {
                    position: absolute;
                    cursor: pointer;
                    top: 0; left: 0; right: 0; bottom: 0;
                    background-color: var(--input-bg);
                    border: 1px solid var(--card-border);
                    transition: .15s;
                    border-radius: 18px;
                }
                
                .slider:before {
                    position: absolute;
                    content: "";
                    height: 10px;
                    width: 10px;
                    left: 3px;
                    bottom: 3px;
                    background-color: var(--text-color);
                    transition: .15s;
                    border-radius: 50%;
                }
                
                input:checked + .slider {
                    background-color: var(--text-color);
                    border-color: var(--text-color);
                }
                
                input:checked + .slider:before {
                    transform: translateX(14px);
                    background-color: var(--toggle-dot-active);
                }
                
                /* Gauges container */
                .gauge-container {
                    display: flex;
                    justify-content: space-around;
                    gap: 20px;
                }
                
                .gauge-card {
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                }
                
                .progress-ring {
                    margin-bottom: 12px;
                }
                
                .progress-ring__circle-bg {
                    stroke: var(--input-bg);
                }
                
                .progress-ring__circle {
                    transition: stroke-dashoffset 0.35s;
                    transform: rotate(-90deg);
                    transform-origin: 50% 50%;
                }
                
                #cpu-circle {
                    stroke: #42b883; /* Green gauge */
                }
                
                #ram-circle {
                    stroke: #e0a96d; /* Yellow gauge */
                }
                
                .gauge-label {
                    font-size: 13px;
                    color: var(--text-muted);
                }
                
                .gauge-val-text {
                    font-family: var(--font-sans);
                    font-size: 18px;
                    font-weight: 500;
                    fill: var(--text-color);
                }
                
                /* Theme Toggle Button */
                .theme-btn {
                    background: var(--card-bg);
                    border: 1px solid var(--card-border);
                    color: var(--text-color);
                    padding: 6px 14px;
                    border-radius: 4px;
                    cursor: pointer;
                    font-size: 12px;
                    font-weight: 500;
                    transition: all 0.15s;
                    display: flex;
                    align-items: center;
                    gap: 6px;
                }
                
                .theme-btn:hover {
                    border-color: var(--card-border-hover);
                    background: var(--input-bg);
                }
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <div style="display: flex; align-items: center; gap: 12px;">
                        <span style="font-size: 24px; font-family: var(--font-serif);"></span>
                        <h1>MacHead 远程控制台</h1>
                    </div>
                    <button class="theme-btn" onclick="toggleTheme()" id="theme-btn">
                        <span id="theme-icon">🌙</span>
                        <span id="theme-text">深色模式</span>
                    </button>
                </header>
                
                <!-- Hardware Gauges -->
                <div class="card" style="margin-bottom: 20px;">
                    <div class="card-title">系统硬件负载</div>
                    <div class="gauge-container">
                        <div class="gauge-card">
                            <svg class="progress-ring" width="120" height="120">
                                <circle class="progress-ring__circle-bg" stroke-width="6" fill="transparent" r="50" cx="60" cy="60"/>
                                <circle class="progress-ring__circle" id="cpu-circle" stroke-width="6" fill="transparent" r="50" cx="60" cy="60"/>
                                <text x="60" y="66" text-anchor="middle" class="gauge-val-text" id="cpu-text">0%</text>
                            </svg>
                            <div class="gauge-label">CPU 占用率</div>
                        </div>
                        
                        <div class="gauge-card">
                            <svg class="progress-ring" width="120" height="120">
                                <circle class="progress-ring__circle-bg" stroke-width="6" fill="transparent" r="50" cx="60" cy="60"/>
                                <circle class="progress-ring__circle" id="ram-circle" stroke-width="6" fill="transparent" r="50" cx="60" cy="60"/>
                                <text x="60" y="66" text-anchor="middle" class="gauge-val-text" id="ram-text">0%</text>
                            </svg>
                            <div class="gauge-label">内存压力</div>
                        </div>
                    </div>
                </div>

                <div class="grid">
                    <!-- Mode Card -->
                    <div class="card">
                        <div class="card-title">系统运行状态</div>
                        <div class="card-value" id="mode-text">
                            <span class="status-dot" id="mode-dot"></span>
                            <span id="mode-label" style="font-size: 20px; font-weight: 500; margin-left: 6px;">正在连接...</span>
                        </div>
                        <div style="margin-top:12px; font-size:12.5px; color:var(--text-muted); line-height: 1.4;">
                            工作站模式决定内置显示器和供电唤醒断言是否锁死。
                        </div>
                    </div>
                    
                    <!-- Battery Card -->
                    <div class="card">
                        <div class="card-title">电池与电源保护</div>
                        <div class="card-value">
                            <span id="battery-capacity">--%</span>
                            <span id="charging-indicator" style="font-size:18px; color:#e0a96d; display:none; margin-left: 8px;">⚡️</span>
                        </div>
                        <div style="margin-top:12px; font-size:12.5px; color:var(--text-muted); line-height: 1.4;" id="power-source-text">
                            正在查询电源状态...
                        </div>
                    </div>
                </div>
                
                <div class="grid">
                    <!-- Controls Card -->
                    <div class="card" style="grid-column: span 2;">
                        <div class="card-title">设备远程控制</div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">MacBook Headless 模式</div>
                                <div class="control-desc">关闭内置屏幕以模拟独立 Mac Studio 行为。</div>
                            </div>
                            <label class="switch">
                                <input type="checkbox" id="headless-toggle" onchange="toggleSetting('headless')">
                                <span class="slider"></span>
                            </label>
                        </div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">防止空闲睡眠</div>
                                <div class="control-desc">保持系统常亮，合盖不休眠。</div>
                            </div>
                            <label class="switch">
                                <input type="checkbox" id="sleep-toggle" onchange="toggleSetting('sleep')">
                                <span class="slider"></span>
                            </label>
                        </div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">禁用内置触控板</div>
                                <div class="control-desc">检测到外接鼠标时，自动关闭触控板输入以防误触。</div>
                            </div>
                            <label class="switch">
                                <input type="checkbox" id="trackpad-toggle" onchange="toggleSetting('trackpad')">
                                <span class="slider"></span>
                            </label>
                        </div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">无头模式下禁用键盘和触控板</div>
                                <div class="control-desc">进入无头模式后，自动屏蔽内置键盘按键与内置触控板输入以防误触。</div>
                            </div>
                            <label class="switch">
                                <input type="checkbox" id="keyboard-toggle" onchange="toggleSetting('keyboard-headless')">
                                <span class="slider"></span>
                            </label>
                        </div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">静音内置麦克风</div>
                                <div class="control-desc">保护物理隐私，进入无头模式时静音系统麦克风。</div>
                            </div>
                            <label class="switch">
                                <input type="checkbox" id="microphone-toggle" onchange="toggleSetting('microphone')">
                                <span class="slider"></span>
                            </label>
                        </div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">断开外接显示器时自动退出</div>
                                <div class="control-desc">检测到所有外接显示器断开时，自动恢复内置屏幕防黑屏。</div>
                            </div>
                            <label class="switch">
                                <input type="checkbox" id="exit-disconnect-toggle" onchange="toggleSetting('exit-disconnect')">
                                <span class="slider"></span>
                            </label>
                        </div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">接入外接显示器时自动恢复</div>
                                <div class="control-desc">有外接显示器重新接入时，自动重入 Headless 并屏蔽内置屏。</div>
                            </div>
                            <label class="switch">
                                <input type="checkbox" id="restore-connect-toggle" onchange="toggleSetting('restore-connect')">
                                <span class="slider"></span>
                            </label>
                        </div>
                    </div>
                </div>
            </div>
            
            <script>
                function setProgress(circleId, percent) {
                    const circle = document.getElementById(circleId);
                    const radius = circle.r.baseVal.value;
                    const circumference = radius * 2 * Math.PI;
                    circle.style.strokeDasharray = `${circumference} ${circumference}`;
                    const offset = circumference - (percent / 100 * circumference);
                    circle.style.strokeDashoffset = offset;
                }

                async function fetchStatus() {
                    try {
                        const response = await fetch('/api/status');
                        const data = await response.json();
                        updateUI(data);
                    } catch (err) {
                        console.error("Failed to fetch status:", err);
                    }
                }

                // Theme Toggle Logic
                function initTheme() {
                    const savedTheme = localStorage.getItem('theme');
                    if (savedTheme) {
                        setTheme(savedTheme);
                    } else {
                        const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
                        setTheme(systemDark ? 'dark' : 'light');
                    }
                }

                function setTheme(theme) {
                    document.body.setAttribute('data-theme', theme);
                    localStorage.setItem('theme', theme);
                    const btnIcon = document.getElementById('theme-icon');
                    const btnText = document.getElementById('theme-text');
                    if (theme === 'dark') {
                        btnIcon.innerText = '☀️';
                        btnText.innerText = '浅色模式';
                    } else {
                        btnIcon.innerText = '🌙';
                        btnText.innerText = '深色模式';
                    }
                }

                function toggleTheme() {
                    const currentTheme = document.body.getAttribute('data-theme') || 'light';
                    setTheme(currentTheme === 'dark' ? 'light' : 'dark');
                }

                initTheme();

                function updateUI(data) {
                    const modeDot = document.getElementById('mode-dot');
                    const modeLabel = document.getElementById('mode-label');
                    const headlessToggle = document.getElementById('headless-toggle');
                    
                    if (data.headlessModeEnabled) {
                        modeDot.className = "status-dot active";
                        modeLabel.innerText = "MacBook Headless 激活";
                        headlessToggle.checked = true;
                    } else {
                        modeDot.className = "status-dot inactive";
                        modeLabel.innerText = "Normal 模式 (显示正常)";
                        headlessToggle.checked = false;
                    }
                    
                    document.getElementById('sleep-toggle').checked = data.preventIdleSleep;
                    document.getElementById('trackpad-toggle').checked = data.trackpadDisabled;
                    document.getElementById('keyboard-toggle').checked = data.keyboardAndTrackpadDisabledInHeadless;
                    document.getElementById('microphone-toggle').checked = data.microphoneMuted;
                    document.getElementById('exit-disconnect-toggle').checked = data.autoExitHeadlessOnDisconnect;
                    document.getElementById('restore-connect-toggle').checked = data.autoRestoreHeadlessOnConnect;
                    
                    document.getElementById('battery-capacity').innerText = `${data.batteryCapacity}%`;
                    document.getElementById('charging-indicator').style.display = data.isCharging ? 'inline' : 'none';
                    document.getElementById('power-source-text').innerText = 
                        data.powerState === "AC Power" ? "正在通过外接电源供电" : "正在通过电池供电（警告：未接电源）";
                    
                    const cpuVal = Math.round(data.cpuUsage);
                    const ramVal = Math.round(data.memoryUsage);
                    document.getElementById('cpu-text').textContent = `${cpuVal}%`;
                    document.getElementById('ram-text').textContent = `${ramVal}%`;
                    setProgress('cpu-circle', cpuVal);
                    setProgress('ram-circle', ramVal);
                }

                async function toggleSetting(type) {
                    let url = '';
                    switch(type) {
                        case 'headless': url = '/api/toggle-headless'; break;
                        case 'sleep': url = '/api/toggle-sleep'; break;
                        case 'trackpad': url = '/api/toggle-trackpad'; break;
                        case 'keyboard-headless': url = '/api/toggle-keyboard-headless'; break;
                        case 'microphone': url = '/api/toggle-microphone'; break;
                        case 'exit-disconnect': url = '/api/toggle-exit-on-disconnect'; break;
                        case 'restore-connect': url = '/api/toggle-restore-on-connect'; break;
                    }
                    
                    try {
                        const response = await fetch(url, { method: 'POST' });
                        const data = await response.json();
                        updateUI(data);
                    } catch (err) {
                        console.error(`Failed to toggle ${type}:`, err);
                    }
                }

                fetchStatus();
                setInterval(fetchStatus, 3000);
            </script>
        </body>
        </html>
        """
    }
}
