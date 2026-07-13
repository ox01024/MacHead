import Foundation

public final class UptimeKumaService {
    public static let shared = UptimeKumaService()
    
    private var timer: Timer?
    private var isServiceRunning = false
    
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
        
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("UptimeKumaService: Heartbeat push failed - \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    // Success
                } else {
                    print("UptimeKumaService: Heartbeat push returned status \(httpResponse.statusCode)")
                }
            }
        }
        task.resume()
    }
}
