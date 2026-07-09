import SwiftUI
import Combine
import Security

/// How the app should follow (or override) the system light/dark appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    /// `nil` means "follow the system"; SwiftUI's `preferredColorScheme(nil)`.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Article body text size, applied to reading views.
enum ArticleFontSize: String, CaseIterable, Identifiable {
    case small, medium, large, xLarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        case .xLarge: return "X-Large"
        }
    }
    var pointSize: CGFloat {
        switch self {
        case .small:  return 15
        case .medium: return 18
        case .large:  return 21
        case .xLarge: return 24
        }
    }
}

/// The OpenAI text-to-speech voices compatible with the `tts-1` model.
enum TTSVoice: String, CaseIterable, Identifiable {
    case alloy, echo, fable, onyx, nova, shimmer
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// User preferences: appearance, article text size, and OpenAI credentials for
/// the Listen (text-to-speech) feature. Simple values persist to `UserDefaults`;
/// the API key lives in the Keychain so it survives launches securely.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var appearance: AppearanceMode = .system {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var fontSize: ArticleFontSize = .medium {
        didSet { defaults.set(fontSize.rawValue, forKey: Keys.fontSize) }
    }
    @Published var voice: TTSVoice = .alloy {
        didSet { defaults.set(voice.rawValue, forKey: Keys.voice) }
    }
    /// The OpenAI API key. Mirrored to the Keychain on every change.
    @Published var apiKey: String = "" {
        didSet { Keychain.set(apiKey.isEmpty ? nil : apiKey, for: Keys.apiKey) }
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let appearance = "appearance"
        static let fontSize = "articleFontSize"
        static let voice = "ttsVoice"
        static let apiKey = "openai.apiKey"
    }

    init() {
        // Load persisted values. (Observers don't fire for a class's own
        // properties during its initializer, so nothing is written back here.)
        if let mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") {
            appearance = mode
        }
        if let size = ArticleFontSize(rawValue: defaults.string(forKey: Keys.fontSize) ?? "") {
            fontSize = size
        }
        if let v = TTSVoice(rawValue: defaults.string(forKey: Keys.voice) ?? "") {
            voice = v
        }
        apiKey = Keychain.get(Keys.apiKey) ?? ""
    }
}

/// A tiny Keychain wrapper for a single string value per account key.
enum Keychain {
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }
}
