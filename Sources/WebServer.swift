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
                        MediaDeviceManager.shared.unmuteBuiltInMicrophone()
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
          "memoryUsage": \(ram)
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
            <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;700&display=swap" rel="stylesheet">
            <style>
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    font-family: 'Outfit', sans-serif;
                    background: radial-gradient(circle at top right, #1d213a, #0c0e17);
                    color: #e5e9f0;
                    min-height: 100vh;
                    padding: 40px 20px;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                }
                .container {
                    width: 100%;
                    max-width: 900px;
                }
                header {
                    display: flex;
                    align-items: center;
                    margin-bottom: 40px;
                    gap: 16px;
                }
                header h1 {
                    font-size: 28px;
                    font-weight: 700;
                    letter-spacing: -0.5px;
                    background: linear-gradient(135deg, #00f0ff, #0072ff);
                    -webkit-background-clip: text;
                    -webkit-text-fill-color: transparent;
                }
                .grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
                    gap: 20px;
                    margin-bottom: 20px;
                }
                .card {
                    background: rgba(255, 255, 255, 0.03);
                    backdrop-filter: blur(20px);
                    -webkit-backdrop-filter: blur(20px);
                    border: 1px solid rgba(255, 255, 255, 0.08);
                    border-radius: 24px;
                    padding: 24px;
                    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2);
                    transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
                }
                .card:hover {
                    border-color: rgba(255, 255, 255, 0.15);
                    transform: translateY(-4px);
                }
                .card-title {
                    font-size: 14px;
                    font-weight: 600;
                    text-transform: uppercase;
                    letter-spacing: 1px;
                    color: #8f9aa9;
                    margin-bottom: 16px;
                }
                .card-value {
                    font-size: 32px;
                    font-weight: 700;
                    color: #ffffff;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                }
                .control-row {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    padding: 16px 0;
                    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
                }
                .control-row:last-child {
                    border-bottom: none;
                }
                .control-label {
                    font-weight: 600;
                    font-size: 16px;
                }
                .control-desc {
                    font-size: 12px;
                    color: #8f9aa9;
                    margin-top: 4px;
                }
                .status-dot {
                    width: 10px;
                    height: 10px;
                    border-radius: 50%;
                    display: inline-block;
                }
                .status-dot.active {
                    background-color: #00e676;
                    box-shadow: 0 0 12px #00e676;
                }
                .status-dot.inactive {
                    background-color: #ff5252;
                    box-shadow: 0 0 12px #ff5252;
                }
                
                /* Toggle Switch */
                .switch {
                    position: relative;
                    display: inline-block;
                    width: 48px;
                    height: 28px;
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
                    background-color: rgba(255, 255, 255, 0.1);
                    transition: .3s;
                    border-radius: 34px;
                }
                .slider:before {
                    position: absolute;
                    content: "";
                    height: 20px;
                    width: 20px;
                    left: 4px;
                    bottom: 4px;
                    background-color: white;
                    transition: .3s;
                    border-radius: 50%;
                }
                input:checked + .slider {
                    background-image: linear-gradient(135deg, #00f0ff, #0072ff);
                }
                input:checked + .slider:before {
                    transform: translateX(20px);
                }
                
                /* Gauges */
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
                    stroke: rgba(255, 255, 255, 0.05);
                }
                .progress-ring__circle {
                    transition: stroke-dashoffset 0.35s;
                    transform: rotate(-90deg);
                    transform-origin: 50% 50%;
                    stroke: url(#gradient);
                }
                .gauge-label {
                    font-size: 14px;
                    font-weight: 600;
                    color: #8f9aa9;
                }
                .gauge-val-text {
                    font-size: 20px;
                    font-weight: 700;
                    color: white;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <div style="font-size:36px"></div>
                    <h1>MacHead Remote 控制面板</h1>
                </header>
                
                <div class="grid">
                    <!-- Mode Card -->
                    <div class="card">
                        <div class="card-title">系统状态</div>
                        <div class="card-value" id="mode-text">
                            <span class="status-dot" id="mode-dot"></span>
                            <span id="mode-label">正在连接...</span>
                        </div>
                        <div style="margin-top:12px; font-size:13px; color:#8f9aa9;">
                            工作站模式决定内置显示器和供电断言是否锁死。
                        </div>
                    </div>
                    
                    <!-- Battery Card -->
                    <div class="card">
                        <div class="card-title">电池与电源</div>
                        <div class="card-value">
                            <span id="battery-capacity">--%</span>
                            <span id="charging-indicator" style="font-size:20px; color:#ffd60a; display:none;">⚡️</span>
                        </div>
                        <div style="margin-top:12px; font-size:13px; color:#8f9aa9;" id="power-source-text">
                            正在查询电源状态...
                        </div>
                    </div>
                </div>
                
                <div class="grid">
                    <!-- Controls Card -->
                    <div class="card" style="grid-column: span 2;">
                        <div class="card-title">设备控制</div>
                        
                        <div class="control-row">
                            <div>
                                <div class="control-label">MacBook Headless 模式</div>
                                <div class="control-desc">切断内置屏幕以模拟独立 Mac Studio 行为。</div>
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
                    </div>
                </div>
                
                <!-- Hardware Gauges -->
                <div class="card" style="margin-bottom: 40px;">
                    <div class="card-title">系统硬件负载</div>
                    <div class="gauge-container">
                        <div class="gauge-card">
                            <svg class="progress-ring" width="120" height="120">
                                <defs>
                                    <linearGradient id="gradient" x1="0%" y1="0%" x2="100%" y2="100%">
                                        <stop offset="0%" stop-color="#00f0ff" />
                                        <stop offset="100%" stop-color="#0072ff" />
                                    </linearGradient>
                                </defs>
                                <circle class="progress-ring__circle-bg" stroke-width="8" fill="transparent" r="50" cx="60" cy="60"/>
                                <circle class="progress-ring__circle" id="cpu-circle" stroke-width="8" fill="transparent" r="50" cx="60" cy="60"/>
                                <text x="60" y="65" text-anchor="middle" class="gauge-val-text" id="cpu-text">0%</text>
                            </svg>
                            <div class="gauge-label">CPU 占用率</div>
                        </div>
                        
                        <div class="gauge-card">
                            <svg class="progress-ring" width="120" height="120">
                                <circle class="progress-ring__circle-bg" stroke-width="8" fill="transparent" r="50" cx="60" cy="60"/>
                                <circle class="progress-ring__circle" id="ram-circle" stroke-width="8" fill="transparent" r="50" cx="60" cy="60"/>
                                <text x="60" y="65" text-anchor="middle" class="gauge-val-text" id="ram-text">0%</text>
                            </svg>
                            <div class="gauge-label">内存 压力</div>
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
