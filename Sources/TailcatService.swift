import Foundation
import CryptoKit
import AppKit

extension Notification.Name {
    public static let tailcatStatusChanged = Notification.Name("com.waffle.MacHead.tailcatStatusChanged")
    public static let tailcatAccountChanged = Notification.Name("com.waffle.MacHead.tailcatAccountChanged")
}

public enum TailcatStatus: Equatable {
    case stopped
    case connecting
    case connected(tcAddr: String)
    case error(message: String)
}

public final class TailcatService {
    public static let shared = TailcatService()

    private var process: Process?
    private var isServiceRunning = false
    private var startGeneration: UInt64 = 0
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var stdoutBuffer = ""
    private var deviceHeartbeatTimer: Timer?
    private var authPollTimer: Timer?
    private lazy var cachedHostName: String = Host.current().localizedName ?? "MacHead"

    public private(set) var currentTcAddr: String = ""
    public private(set) var isWaitingForBrowserAuth: Bool = false
    public private(set) var isDeviceSyncedToAccount: Bool = false
    public private(set) var cachedAvatarImage: NSImage? = nil
    private var cachedAccountToken: String = ""

    public var isAccountLoggedIn: Bool {
        return !accountToken.isEmpty
    }

    private var accountToken: String {
        if !cachedAccountToken.isEmpty {
            return cachedAccountToken
        }
        let loaded = loadEncryptedAccountToken()
        cachedAccountToken = loaded
        return loaded
    }

    public var loggedInUserName: String {
        return UserDefaults.standard.string(forKey: "tailcatAccountName") ?? ""
    }

    public var loggedInProvider: String {
        return UserDefaults.standard.string(forKey: "tailcatAccountProvider") ?? ""
    }

    public var loggedInEmail: String {
        return UserDefaults.standard.string(forKey: "tailcatAccountEmail") ?? ""
    }

    public var loggedInAvatarUrl: String {
        return UserDefaults.standard.string(forKey: "tailcatAccountAvatarUrl") ?? ""
    }

    public var deviceId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "tailcatDeviceId"), !existing.isEmpty {
            return existing
        }
        let generated = "mac_\(UUID().uuidString.lowercased())"
        defaults.set(generated, forKey: "tailcatDeviceId")
        return generated
    }

    public var webTerminalBaseUrl: String {
        let custom = (UserDefaults.standard.string(forKey: "tailcatWebBaseUrl") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return custom.hasSuffix("/") ? String(custom.dropLast()) : custom
        }
        return "https://dash.headlessmac.com"
    }

    public var dashEntryUrl: String {
        let savedBase = UserDefaults.standard.string(forKey: "tailcatAccountBaseUrl") ?? ""
        if !savedBase.isEmpty && !savedBase.hasPrefix("http://localhost:") {
            return savedBase
        }
        return webTerminalBaseUrl
    }

    private var candidateApiBases: [String] {
        var bases: [String] = []
        let savedBase = (UserDefaults.standard.string(forKey: "tailcatAccountBaseUrl") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedBase.isEmpty && !savedBase.hasPrefix("http://localhost:") {
            bases.append(savedBase)
        }
        if !bases.contains(webTerminalBaseUrl) {
            bases.append(webTerminalBaseUrl)
        }
        return bases
    }

    public private(set) var currentStatus: TailcatStatus = .stopped {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .tailcatStatusChanged, object: self.currentStatus)
            }
        }
    }

    private init() {
        migrateLegacyAccountTokenIfNeeded()
        NotificationCenter.default.addObserver(
            forName: .headlessModeStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncDeviceToAccount()
        }
        refreshAvatarImageIfNeeded()
    }

    public func refreshAvatarImageIfNeeded() {
        let urlStr = loggedInAvatarUrl
        guard isAccountLoggedIn, !urlStr.isEmpty, let url = URL(string: urlStr) else {
            cachedAvatarImage = nil
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.cachedAvatarImage = img
                NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)
            }
        }.resume()
    }

    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support")
        return base.appendingPathComponent("MacHead/tailcat", isDirectory: true)
    }

    public static var persistentKeyPath: String {
        return appSupportDirectory.appendingPathComponent("persistent.private.json").path
    }

    private static var encryptedTokenPath: String {
        return appSupportDirectory.appendingPathComponent("account_token.enc").path
    }

    private static var vaultSeedPath: String {
        return appSupportDirectory.appendingPathComponent(".vault_key").path
    }

    private func resolveVaultSymmetricKey() -> SymmetricKey {
        let dir = Self.appSupportDirectory
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        _ = chmod(dir.path, S_IRWXU)

        let seedPath = Self.vaultSeedPath
        var seedData: Data
        if let existing = try? Data(contentsOf: URL(fileURLWithPath: seedPath)), existing.count >= 32 {
            seedData = existing
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            seedData = Data(bytes)
            try? seedData.write(to: URL(fileURLWithPath: seedPath), options: .atomic)
            _ = chmod(seedPath, S_IRUSR | S_IWUSR)
        }
        var combined = seedData
        combined.append(Data(deviceId.utf8))
        let digest = SHA256.hash(data: combined)
        return SymmetricKey(data: Data(digest))
    }

    private func saveEncryptedAccountToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedAccountToken = trimmed
        UserDefaults.standard.removeObject(forKey: "tailcatAccountToken")
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(atPath: Self.encryptedTokenPath)
            return
        }
        let key = resolveVaultSymmetricKey()
        if let sealed = try? AES.GCM.seal(Data(trimmed.utf8), using: key),
           let combined = sealed.combined {
            try? combined.write(to: URL(fileURLWithPath: Self.encryptedTokenPath), options: .atomic)
            _ = chmod(Self.encryptedTokenPath, S_IRUSR | S_IWUSR)
        }
    }

    private func loadEncryptedAccountToken() -> String {
        if let encData = try? Data(contentsOf: URL(fileURLWithPath: Self.encryptedTokenPath)),
           let box = try? AES.GCM.SealedBox(combined: encData),
           let decData = try? AES.GCM.open(box, using: resolveVaultSymmetricKey()),
           let str = String(data: decData, encoding: .utf8),
           !str.isEmpty {
            return str
        }
        if let legacy = UserDefaults.standard.string(forKey: "tailcatAccountToken"), !legacy.isEmpty {
            saveEncryptedAccountToken(legacy)
            return legacy
        }
        return ""
    }

    private func migrateLegacyAccountTokenIfNeeded() {
        if let legacy = UserDefaults.standard.string(forKey: "tailcatAccountToken"), !legacy.isEmpty {
            saveEncryptedAccountToken(legacy)
        } else {
            cachedAccountToken = loadEncryptedAccountToken()
        }
    }

    public func findBinaryPath() -> String? {
        let defaults = UserDefaults.standard
        if let customPath = defaults.string(forKey: "tailcatBinaryPath"),
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }

        let binaryName = "tailcat"
        let possiblePaths: [String?] = [
            Bundle.main.path(forResource: binaryName, ofType: nil),
            "/Applications/MacHead.app/Contents/Resources/\(binaryName)",
            "\(FileManager.default.currentDirectoryPath)/Resources/\(binaryName)",
            "\(Bundle.main.bundlePath)/Contents/Resources/\(binaryName)",
            "\(NSHomeDirectory())/Library/Application Support/MacHead/bin/\(binaryName)",
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
            "\(NSHomeDirectory())/go/bin/\(binaryName)",
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
        guard isAccountLoggedIn || defaults.bool(forKey: "tailcatEnabled") else {
            currentStatus = .stopped
            return
        }

        guard let binaryPath = findBinaryPath() else {
            currentStatus = .error(message: L(
                "未找到内置 tailcat 组件，请执行 ./Scripts/build-tailcat.sh 或重新安装应用",
                "Bundled tailcat binary not found. Please run ./Scripts/build-tailcat.sh or reinstall MacHead."
            ))
            return
        }

        isServiceRunning = true
        startGeneration &+= 1
        let expectedGen = startGeneration
        currentStatus = .connecting
        stdoutBuffer = ""

        let codeMode = defaults.string(forKey: "tailcatCodeMode") ?? "ephemeral"
        let isPersistent = (codeMode == "persistent") || isAccountLoggedIn

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.isServiceRunning, self.startGeneration == expectedGen else { return }

            var keyArg = "--key=new"
            if isPersistent {
                if let keyPath = self.ensurePersistentKey(binaryPath: binaryPath) {
                    keyArg = "--key=\(keyPath)"
                } else {
                    DispatchQueue.main.async {
                        guard self.startGeneration == expectedGen else { return }
                        self.isServiceRunning = false
                        self.currentStatus = .error(message: L("无法生成固定设备密钥文件", "Failed to generate persistent device key file"))
                    }
                    return
                }
            }

            guard self.isServiceRunning, self.startGeneration == expectedGen else { return }

            var args = ["serve", "--json", "--full-address", keyArg, "no-auth-ssh"]
            var env = ProcessInfo.processInfo.environment
            if let execPath = Bundle.main.executablePath {
                env["MACHEAD_APP_BIN"] = execPath
            }

            let requirePassword = defaults.bool(forKey: "tailcatRequirePassword")
            if requirePassword {
                let rawPass = self.effectiveAccessPassword()
                if !rawPass.isEmpty {
                    env["MACHEAD_TERM_PASS_HASH"] = Self.sha256Hex(rawPass)
                    args.append(contentsOf: ["--", binaryPath, "gated-shell"])
                }
            }

            let newProcess = Process()
            newProcess.executableURL = URL(fileURLWithPath: binaryPath)
            newProcess.arguments = args
            newProcess.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            newProcess.standardOutput = outPipe
            newProcess.standardError = errPipe
            self.outputPipe = outPipe
            self.errorPipe = errPipe

            self.setupStdoutObserver(outPipe)
            self.setupStderrObserver(errPipe)

            newProcess.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard let self = self,
                          self.startGeneration == expectedGen,
                          self.process === proc else { return }
                    self.isServiceRunning = false
                    self.process = nil

                    if case .connecting = self.currentStatus {
                        self.currentStatus = .error(message: L(
                            "tailcat 进程异常退出 (代码: \(proc.terminationStatus))",
                            "tailcat process exited unexpectedly (Code: \(proc.terminationStatus))"
                        ))
                    } else if self.isAccountLoggedIn || UserDefaults.standard.bool(forKey: "tailcatEnabled") {
                        self.currentStatus = .connecting
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                            guard let self = self,
                                  self.startGeneration == expectedGen,
                                  self.isAccountLoggedIn || UserDefaults.standard.bool(forKey: "tailcatEnabled"),
                                  !self.isServiceRunning else { return }
                            self.start()
                        }
                    } else {
                        self.currentStatus = .stopped
                    }
                }
            }

            do {
                self.killOrphanedProcesses()
                guard self.isServiceRunning, self.startGeneration == expectedGen else {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    return
                }
                try newProcess.run()
                self.process = newProcess
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard self.startGeneration == expectedGen else { return }
                    self.isServiceRunning = false
                    self.currentStatus = .error(message: L(
                        "无法启动 tailcat: \(error.localizedDescription)",
                        "Failed to start tailcat: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    public func stop() {
        startGeneration &+= 1
        let stopGen = startGeneration
        if Thread.isMainThread {
            stopDeviceHeartbeatTimer()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.stopDeviceHeartbeatTimer()
            }
        }
        isServiceRunning = false
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        if let proc = process {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
            }
        }
        process = nil
        currentTcAddr = ""
        currentStatus = .stopped
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, self.startGeneration == stopGen, !self.isServiceRunning else { return }
            self.killOrphanedProcesses()
        }
    }

    public func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.start()
        }
    }

    public func isRunning() -> Bool {
        return isServiceRunning && (process?.isRunning ?? false)
    }

    public func effectiveAccessPassword() -> String {
        let custom = (UserDefaults.standard.string(forKey: "tailcatAccessPassword") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return custom
        }
        return UserDefaults.standard.string(forKey: "WebServerPassword") ?? ""
    }

    private func ensurePersistentKey(binaryPath: String) -> String? {
        let dir = Self.appSupportDirectory
        let keyPath = Self.persistentKeyPath
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            _ = chmod(dir.path, S_IRWXU)
        } catch {
            return nil
        }

        if FileManager.default.fileExists(atPath: keyPath) {
            _ = chmod(keyPath, S_IRUSR | S_IWUSR)
            return keyPath
        }

        let genProc = Process()
        genProc.executableURL = URL(fileURLWithPath: binaryPath)
        genProc.arguments = ["genkey", "--key=\(keyPath)"]
        do {
            try genProc.run()
            genProc.waitUntilExit()
            if genProc.terminationStatus == 0 && FileManager.default.fileExists(atPath: keyPath) {
                _ = chmod(keyPath, S_IRUSR | S_IWUSR)
                return keyPath
            }
        } catch {
            print("TailcatService: genkey failed: \(error)")
        }
        return nil
    }

    private func setupStdoutObserver(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.stdoutBuffer.append(chunk)
                self.processStdoutBuffer()
            }
        }
    }

    private func processStdoutBuffer() {
        let lines = stdoutBuffer.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { continue }
            if let jsonData = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let listenAddr = obj["listenAddr"] as? String,
               listenAddr.hasPrefix("tc") {
                handleTunnelReady(tcAddr: listenAddr)
                stdoutBuffer = ""
                break
            }
        }
    }

    private func setupStderrObserver(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let output = String(data: data, encoding: .utf8) else { return }
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.lowercased().contains("error:") || trimmed.lowercased().contains("fatal:") {
                    DispatchQueue.main.async {
                        self?.currentStatus = .error(message: trimmed)
                    }
                }
            }
        }
    }

    private func handleTunnelReady(tcAddr: String) {
        currentTcAddr = tcAddr
        currentStatus = .connected(tcAddr: tcAddr)
        syncDeviceToAccount()
        startDeviceHeartbeatTimer()
    }

    // MARK: - Cloud Dash Account Binding & Device Sync

    public func loginWithBrowser(provider: String? = nil, completion: ((Bool, String) -> Void)? = nil) {
        let requestId = UUID().uuidString.lowercased()
        let codeVerifier = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let codeChallenge = Self.sha256Hex(codeVerifier)
        let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=;?#/"))
        let encodedHost = cachedHostName.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? "MacHead"
        let base = webTerminalBaseUrl

        isWaitingForBrowserAuth = true
        NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)

        var urlStr = "\(base)/?app_auth=\(requestId)&code_challenge=\(codeChallenge)&device_name=\(encodedHost)"
        if let p = provider, !p.isEmpty {
            urlStr += "&provider=\(p)"
        }
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
        startPollingAppAuth(
            requestId: requestId,
            codeVerifier: codeVerifier,
            primaryBase: base,
            completion: completion
        )
    }

    public func cancelBrowserAuth() {
        authPollTimer?.invalidate()
        authPollTimer = nil
        isWaitingForBrowserAuth = false
        NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)
    }

    private func startPollingAppAuth(
        requestId: String,
        codeVerifier: String,
        primaryBase: String,
        completion: ((Bool, String) -> Void)?
    ) {
        authPollTimer?.invalidate()
        var attempts = 0
        var bases = [primaryBase]
        for b in candidateApiBases where !bases.contains(b) {
            bases.append(b)
        }

        authPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            attempts += 1
            if attempts > 90 {
                timer.invalidate()
                self.isWaitingForBrowserAuth = false
                NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)
                completion?(false, L("浏览器登录授权超时，请重试", "Browser authorization timed out. Please try again."))
                return
            }

            for base in bases {
                guard let url = URL(string: "\(base)/api/auth?action=poll_app&request_id=\(requestId)&code_verifier=\(codeVerifier)") else { continue }
                var req = URLRequest(url: url)
                req.timeoutInterval = 4
                URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
                    guard let self = self,
                          let http = resp as? HTTPURLResponse,
                          http.statusCode == 200,
                          let data = data,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let status = obj["status"] as? String,
                          status == "approved",
                          let sessionToken = obj["sessionToken"] as? String,
                          let user = obj["user"] as? [String: Any] else {
                        return
                    }
                    DispatchQueue.main.async {
                        guard self.isWaitingForBrowserAuth else { return }
                        self.authPollTimer?.invalidate()
                        self.authPollTimer = nil
                        self.completeAccountLogin(sessionToken: sessionToken, user: user, baseUrl: base)
                        completion?(true, L("账号绑定成功", "Account linked successfully"))
                    }
                }.resume()
            }
        }
    }

    private func completeAccountLogin(sessionToken: String, user: [String: Any], baseUrl: String) {
        isWaitingForBrowserAuth = false
        let defaults = UserDefaults.standard
        let name = (user["name"] as? String) ?? (user["email"] as? String) ?? "MacHead User"
        let provider = (user["provider"] as? String) ?? "github"
        let email = (user["email"] as? String) ?? ""
        let avatarUrl = (user["avatar_url"] as? String) ?? ""

        saveEncryptedAccountToken(sessionToken)
        defaults.set(name, forKey: "tailcatAccountName")
        defaults.set(provider, forKey: "tailcatAccountProvider")
        defaults.set(email, forKey: "tailcatAccountEmail")
        defaults.set(avatarUrl, forKey: "tailcatAccountAvatarUrl")
        defaults.set(baseUrl, forKey: "tailcatAccountBaseUrl")
        defaults.set("persistent", forKey: "tailcatCodeMode")
        defaults.set(true, forKey: "tailcatEnabled")
        refreshAvatarImageIfNeeded()

        if !isRunning() {
            start()
        } else if !currentTcAddr.isEmpty {
            syncDeviceToAccount()
            startDeviceHeartbeatTimer()
        } else {
            restart()
        }

        NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)
    }

    public func logoutAccount() {
        cancelBrowserAuth()
        stopDeviceHeartbeatTimer()

        let defaults = UserDefaults.standard
        let token = accountToken
        let devId = deviceId

        if !token.isEmpty {
            for base in candidateApiBases {
                if let url = URL(string: "\(base)/api/devices?device_id=\(devId)") {
                    var req = URLRequest(url: url)
                    req.httpMethod = "DELETE"
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 5
                    URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
                }
                if let authUrl = URL(string: "\(base)/api/auth") {
                    var authReq = URLRequest(url: authUrl)
                    authReq.httpMethod = "POST"
                    authReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    authReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    authReq.httpBody = Data("{\"action\":\"logout\"}".utf8)
                    authReq.timeoutInterval = 5
                    URLSession.shared.dataTask(with: authReq) { _, _, _ in }.resume()
                }
            }
        }

        saveEncryptedAccountToken("")
        defaults.removeObject(forKey: "tailcatAccountName")
        defaults.removeObject(forKey: "tailcatAccountProvider")
        defaults.removeObject(forKey: "tailcatAccountEmail")
        defaults.removeObject(forKey: "tailcatAccountAvatarUrl")
        defaults.removeObject(forKey: "tailcatAccountBaseUrl")
        defaults.set(false, forKey: "tailcatEnabled")
        cachedAvatarImage = nil
        isDeviceSyncedToAccount = false
        stop()

        // Rotate persistent WireGuard key so any previously issued tc_addr is permanently invalidated
        try? FileManager.default.removeItem(atPath: Self.persistentKeyPath)

        NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)
    }

    public func syncDeviceToAccount() {
        let defaults = UserDefaults.standard
        let token = accountToken
        guard !token.isEmpty, !currentTcAddr.isEmpty else { return }

        let requirePass = defaults.bool(forKey: "tailcatRequirePassword")
        let isHeadless = HeadlessModeController.shared.isHeadlessModeEnabled

        let payload: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": cachedHostName,
            "modelArch": Self.currentMachineArchLabel(),
            "osVersion": Self.currentOSVersionLabel(),
            "isHeadless": isHeadless,
            "requirePass": requirePass,
            "tcAddr": currentTcAddr
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        for base in candidateApiBases {
            guard let url = URL(string: "\(base)/api/devices") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 8
            req.httpBody = bodyData

            URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
                guard err == nil, let http = resp as? HTTPURLResponse else { return }
                if (200...299).contains(http.statusCode) {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if !self.isDeviceSyncedToAccount {
                            self.isDeviceSyncedToAccount = true
                            NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)
                        }
                    }
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if self.isDeviceSyncedToAccount {
                            self.isDeviceSyncedToAccount = false
                            NotificationCenter.default.post(name: .tailcatAccountChanged, object: nil)
                        }
                    }
                }
            }.resume()
        }
    }

    private func startDeviceHeartbeatTimer() {
        stopDeviceHeartbeatTimer()
        guard isAccountLoggedIn else { return }
        deviceHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning(), !self.currentTcAddr.isEmpty else { return }
            self.syncDeviceToAccount()
        }
    }

    private func stopDeviceHeartbeatTimer() {
        deviceHeartbeatTimer?.invalidate()
        deviceHeartbeatTimer = nil
    }

    private static func currentMachineArchLabel() -> String {
        #if arch(arm64)
        return "Apple Silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "macOS"
        #endif
    }

    private static func currentOSVersionLabel() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func killOrphanedProcesses() {
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killTask.arguments = ["-9", "tailcat"]
        try? killTask.run()
        killTask.waitUntilExit()
    }
}
