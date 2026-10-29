import Foundation
import Combine
import SwiftUI

extension Notification.Name {
    public static let appLanguageChanged = Notification.Name("com.waffle.MacHead.appLanguageChanged")
}

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zh = "zh"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            return LocalizationManager.shared.isEnglish ? "Follow System" : "跟随系统"
        case .zh:
            return "简体中文"
        case .en:
            return "English"
        }
    }
}

public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()
    public static let defaultsKey = "AppLanguage"

    @Published public var selectedLanguage: AppLanguage {
        didSet {
            guard oldValue != selectedLanguage else { return }
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Self.defaultsKey)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .appLanguageChanged, object: self.effectiveLanguageCode)
            }
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppLanguage.system.rawValue
        self.selectedLanguage = AppLanguage(rawValue: saved) ?? .system
    }

    /// Returns `"en"` or `"zh"` after resolving `.system` against `Locale.preferredLanguages`.
    public var effectiveLanguageCode: String {
        switch selectedLanguage {
        case .zh:
            return "zh"
        case .en:
            return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh-hans"
            return preferred.hasPrefix("zh") ? "zh" : "en"
        }
    }

    public var isEnglish: Bool {
        effectiveLanguageCode == "en"
    }

    public var locale: Locale {
        Locale(identifier: isEnglish ? "en_US" : "zh_CN")
    }

    public func toggleLanguage() {
        selectedLanguage = isEnglish ? .zh : .en
    }
}

/// Global helper that returns either the Simplified Chinese or English string based on the active language.
@inline(__always)
public func L(_ zh: String, _ en: String) -> String {
    return LocalizationManager.shared.isEnglish ? en : zh
}
