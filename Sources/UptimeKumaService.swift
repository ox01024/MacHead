import Foundation

public enum KumaPushStatus: Equatable {
    case stopped
    case pending
    case success
    case failure(String)
}

public final class UptimeKumaService {
    public static let shared = UptimeKumaService()
    public static let statusChanged = Notification.Name("com.waffle.MacHead.kumaPushStatusChanged")

    private var timer: Timer?
    private var isServiceRunning = false

    public private(set) var status: KumaPushStatus = .stopped {
        didSet {
            NotificationCenter.default.post(name: UptimeKumaService.statusChanged, object: self.status)
        }
    }

    private init() {}
    
    public func start() {
        guard !isServiceRunning else { return }
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "kumaEnabled") else { return }
        
        guard let urlString = defaults.string(forKey: "kumaPushUrl"), !urlString.isEmpty else {
            print("UptimeKumaService: Missing Push URL configuration")
            return
        }
        
        let interval = defaults.double(forKey: "kumaInterval")
        let timeInterval = interval > 0 ? interval : 60.0 // Default to 60s
        
        isServiceRunning = true
        status = .pending
        
        // Start the timer
        timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        
        // Send initial ping immediately
        sendPing()
        print("UptimeKumaService: Heartbeat service started with interval \(timeInterval)s")
    }
    
    public func stop() {
        guard isServiceRunning else { return }
        
        timer?.invalidate()
        timer = nil
        isServiceRunning = false
        status = .stopped
        print("UptimeKumaService: Heartbeat service stopped")
    }
    
    private func sendPing() {
        let defaults = UserDefaults.standard
        guard let urlString = defaults.string(forKey: "kumaPushUrl"),
              var components = URLComponents(string: urlString) else { return }
        
        // Fetch current temperature and fan speed from SMCManager
        let temp = SMCManager.shared.currentTemperature
        let fan = SMCManager.shared.fanSpeed
        let isFanless = SMCManager.shared.isFanless
        
        var messageParts: [String] = []
        if temp > 0 {
            messageParts.append("Temp: \(Int(temp))°C")
        }
        if isFanless {
            messageParts.append("Fanless")
        } else if fan > 0 {
            messageParts.append("Fan: \(fan)RPM")
        }
        
        let statusMsg = messageParts.isEmpty ? "MacHead Active" : messageParts.joined(separator: ", ")
        
        // Append query parameters to Uptime Kuma push URL
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "status", value: "up"))
        queryItems.append(URLQueryItem(name: "msg", value: statusMsg))
        
        // Calculate a dummy/approximate ping latency or skip ping
        // Uptime Kuma will record the message and mark the service as UP
        components.queryItems = queryItems
        
        guard let finalUrl = components.url else { return }
        
        var request = URLRequest(url: finalUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                print("UptimeKumaService: Heartbeat push failed - \(error.localizedDescription)")
                self?.status = .failure(error.localizedDescription)
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    self?.status = .success
                } else {
                    print("UptimeKumaService: Heartbeat push returned status \(httpResponse.statusCode)")
                    self?.status = .failure("HTTP \(httpResponse.statusCode)")
                }
            }
        }
        task.resume()
    }
}
