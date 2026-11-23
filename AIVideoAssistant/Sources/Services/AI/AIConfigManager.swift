//
//  AIConfigManager.swift
//  API Key 使用系统钥匙串存储
//

import Foundation
import KeychainAccess

final class AIConfigManager {
    static let shared = AIConfigManager()

    private let keychain = Keychain(service: "com.aivideoassistant.config")
    private let defaultsKey = "aiConfig.v2"

    private init() {}

    func save(_ config: AIConfig) {
        keychain["openAIKey"] = config.openAIKey
        keychain["azureKey"] = config.azureKey
        keychain["xfyunAPIKey"] = config.xfyunAPIKey
        keychain["xfyunAPISecret"] = config.xfyunAPISecret

        var safe = config
        safe.openAIKey = ""
        safe.azureKey = ""
        safe.xfyunAPIKey = ""
        safe.xfyunAPISecret = ""

        if let data = try? JSONEncoder().encode(safe) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func load() -> AIConfig {
        var config = AIConfig()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(AIConfig.self, from: data) {
            config = saved
        }
        config.openAIKey = (try? keychain.get("openAIKey")) ?? ""
        config.azureKey = (try? keychain.get("azureKey")) ?? ""
        config.xfyunAPIKey = (try? keychain.get("xfyunAPIKey")) ?? ""
        config.xfyunAPISecret = (try? keychain.get("xfyunAPISecret")) ?? ""
        return config
    }

    func clear() {
        try? keychain.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
