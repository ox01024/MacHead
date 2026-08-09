import Foundation
import Combine

public final class IntegrationManager: ObservableObject {
    public static let shared = IntegrationManager()
    
    private var cancellables = Set<AnyCancellable>()
    private var tempCheckTimer: Timer?
    
    private init() {
        setupSMCWatcher()
    }
    
    public func startAllServices() {
        print("IntegrationManager: Starting all active integrations...")
        NezhaAgentService.shared.start()
        ServerStatusService.shared.start()
        UptimeKumaService.shared.start()
        FrpService.shared.start()
        startTemperatureAlertWatcher()
    }
    
    public func stopAllServices() {
        print("IntegrationManager: Stopping all integrations...")
        NezhaAgentService.shared.stop()
        ServerStatusService.shared.stop()
        UptimeKumaService.shared.stop()
        FrpService.shared.stop()
        stopTemperatureAlertWatcher()
    }
    
    public func reloadServices() {
        print("IntegrationManager: Config changed, reloading integrations...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NezhaAgentService.shared.stop()
            ServerStatusService.shared.stop()
            UptimeKumaService.shared.stop()
            FrpService.shared.stop()
            
            Thread.sleep(forTimeInterval: 0.2)
            
            NezhaAgentService.shared.start()
            ServerStatusService.shared.start()
            UptimeKumaService.shared.start()
            FrpService.shared.start()
            
            DispatchQueue.main.async {
                self?.stopTemperatureAlertWatcher()
                self?.startTemperatureAlertWatcher()
            }
        }
    }
    
    private func setupSMCWatcher() {
        // Observe SMCManager temperature updates
        SMCManager.shared.$currentTemperature
            .receive(on: RunLoop.main)
            .sink { [weak self] temp in
                self?.evaluateTemperature(temp)
            }
            .store(in: &cancellables)
    }
    
    private func startTemperatureAlertWatcher() {
        tempCheckTimer?.invalidate()
        tempCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.evaluateTemperature(SMCManager.shared.currentTemperature)
        }
    }
    
    private func stopTemperatureAlertWatcher() {
        tempCheckTimer?.invalidate()
        tempCheckTimer = nil
    }
    
    private func evaluateTemperature(_ temp: Double) {
        guard temp > 15.0 else { return } // Ignore invalid startup reads
        
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "notificationsEnabled") && defaults.bool(forKey: "overheatAlertEnabled") else { return }
        
        let threshold = defaults.double(forKey: "overheatThreshold")
        let limit = threshold > 0 ? threshold : 85.0 // Default to 85°C
        
        if temp >= limit {
            NotificationService.shared.sendAlert(
                type: .overheat,
                title: "芯片核心温度过高 ⚠️",
                body: "当前 Mac 处理器温度已达到 \(Int(temp))°C，超过了设定的安全阈值（\(Int(limit))°C）。请检查合盖摆放位置与散热情况。"
            )
        }
    }
}
