import Foundation

public final class NezhaAgentService {
    public static let shared = NezhaAgentService()
    
    private var process: Process?
    private var isServiceRunning = false
    
    private init() {}
    
    public func start() {
        guard !isServiceRunning else { return }
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "nezhaEnabled") else { return }
        
        guard let server = defaults.string(forKey: "nezhaServer"), !server.isEmpty,
              let secret = defaults.string(forKey: "nezhaSecret"), !secret.isEmpty else {
            print("NezhaAgentService: Missing server or secret configuration")
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
            return
        }
        
        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: path)
        
        var arguments = ["-s", server, "-p", secret]
        if defaults.bool(forKey: "nezhaTls") {
            arguments.append("--tls")
        }
        
        newProcess.arguments = arguments
        
        // Redirect logs to prevent stdout flooding
        let nullDevice = FileHandle.nullDevice
        newProcess.standardOutput = nullDevice
        newProcess.standardError = nullDevice
        
        newProcess.terminationHandler = { [weak self] proc in
            print("NezhaAgentService: nezha-agent process terminated with status \(proc.terminationStatus)")
            self?.isServiceRunning = false
            
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
        }
    }
    
    public func stop() {
        guard isServiceRunning else { return }
        
        print("NezhaAgentService: Stopping nezha-agent...")
        
        // Disable termination handler temporarily to prevent auto-restart loop
        process?.terminationHandler = nil
        
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        
        process = nil
        isServiceRunning = false
    }
    
    public func isRunning() -> Bool {
        return isServiceRunning && (process?.isRunning ?? false)
    }
}
