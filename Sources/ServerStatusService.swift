import Foundation

public final class ServerStatusService {
    public static let shared = ServerStatusService()
    
    private var process: Process?
    private var isServiceRunning = false
    
    private init() {}
    
    public func start() {
        guard !isServiceRunning else { return }
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "serverStatusEnabled") else { return }
        
        guard let addr = defaults.string(forKey: "serverStatusAddr"), !addr.isEmpty,
              let user = defaults.string(forKey: "serverStatusUser"), !user.isEmpty,
              let password = defaults.string(forKey: "serverStatusPassword"), !password.isEmpty else {
            print("ServerStatusService: Missing address, user, or password configuration")
            return
        }
        
        let binaryName = "serverstatus-client"
        var binaryPath = Bundle.main.path(forResource: binaryName, ofType: nil)
        
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
            print("ServerStatusService: Binary \(binaryName) not found in resources")
            return
        }
        
        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: path)
        newProcess.arguments = [
            "-a", addr,
            "-u", user,
            "-p", password
        ]
        
        let nullDevice = FileHandle.nullDevice
        newProcess.standardOutput = nullDevice
        newProcess.standardError = nullDevice
        
        newProcess.terminationHandler = { [weak self] proc in
            print("ServerStatusService: serverstatus-client process terminated with status \(proc.terminationStatus)")
            self?.isServiceRunning = false
            
            // Auto restart if configured to be running
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                let stillEnabled = UserDefaults.standard.bool(forKey: "serverStatusEnabled")
                if stillEnabled && !self.isServiceRunning {
                    print("ServerStatusService: Attempting auto-restart...")
                    self.start()
                }
            }
        }
        
        do {
            try newProcess.run()
            self.process = newProcess
            self.isServiceRunning = true
            print("ServerStatusService: Successfully started serverstatus-client reporting to \(addr)")
        } catch {
            print("ServerStatusService: Failed to launch serverstatus-client - \(error.localizedDescription)")
        }
    }
    
    public func stop() {
        guard isServiceRunning else { return }
        
        print("ServerStatusService: Stopping serverstatus-client...")
        let procToStop = self.process
        self.process = nil
        self.isServiceRunning = false
        
        DispatchQueue.global(qos: .userInitiated).async {
            procToStop?.terminationHandler = nil
            if let proc = procToStop, proc.isRunning {
                proc.terminate()
            }
        }
    }
    
    public func isRunning() -> Bool {
        return isServiceRunning && (process?.isRunning ?? false)
    }
}
