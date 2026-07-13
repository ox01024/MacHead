import Foundation

public enum AlertType: String {
    case powerDisconnect = "powerDisconnect"
    case lowBattery = "lowBattery"
    case overheat = "overheat"
    case test = "test"
}

public final class NotificationService {
    public static let shared = NotificationService()
    
    private var lastSentAlerts: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 3600 // 1 hour cooldown per alert type
    
    private init() {}
    
    /// Sends an alert notification if it passes the cooldown check.
    /// - Parameters:
    ///   - type: The category/type of the alert (used for rate-limiting cooldown)
    ///   - title: Title of the notification
    ///   - body: Content of the notification
    ///   - force: Set to true to bypass the rate-limiting cooldown (e.g., for test notifications)
    public func sendAlert(type: AlertType, title: String, body: String, force: Bool = false) {
        let defaults = UserDefaults.standard
        let notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        
        // Only proceed if notifications are enabled, or if it is a forced test alert
        guard notificationsEnabled || type == .test || force else { return }
        
        let now = Date()
        if !force && type != .test {
            if let lastSent = lastSentAlerts[type.rawValue], now.timeIntervalSince(lastSent) < cooldownInterval {
                print("NotificationService: Suppressing alert \(type.rawValue) due to cooldown. Last sent: \(lastSent)")
                return
            }
        }
        
        // Record timestamp
        lastSentAlerts[type.rawValue] = now
        
        let formattedTitle = "[MacHead] \(title)"
        
        // Send via Bark if configured
        if defaults.bool(forKey: "barkEnabled"), let barkKey = defaults.string(forKey: "barkKey"), !barkKey.isEmpty {
            sendBarkNotification(key: barkKey, title: formattedTitle, body: body)
        }
        
        // Send via Telegram if configured
        if defaults.bool(forKey: "telegramEnabled"),
           let botToken = defaults.string(forKey: "telegramBotToken"), !botToken.isEmpty,
           let chatId = defaults.string(forKey: "telegramChatId"), !chatId.isEmpty {
            sendTelegramNotification(token: botToken, chatId: chatId, message: "\(formattedTitle)\n\n\(body)")
        }
    }
    
    private func sendBarkNotification(key: String, title: String, body: String) {
        guard let url = URL(string: "https://api.day.app/push") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "device_key": key,
            "title": title,
            "body": body,
            "sound": "alarm",
            "group": "MacHead"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("NotificationService: Bark push failed - \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse {
                    print("NotificationService: Bark push responded with status \(httpResponse.statusCode)")
                }
            }
            task.resume()
        } catch {
            print("NotificationService: Failed to serialize Bark payload - \(error.localizedDescription)")
        }
    }
    
    private func sendTelegramNotification(token: String, chatId: String, message: String) {
        let urlString = "https://api.telegram.org/bot\(token)/sendMessage"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": message
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("NotificationService: Telegram push failed - \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse {
                    print("NotificationService: Telegram push responded with status \(httpResponse.statusCode)")
                }
            }
            task.resume()
        } catch {
            print("NotificationService: Failed to serialize Telegram payload - \(error.localizedDescription)")
        }
    }
}
