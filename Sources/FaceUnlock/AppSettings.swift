import Foundation

/// App 配置，落在包内 settings.json，不使用 UserDefaults，避免 ~/Library/Preferences 残留。
struct AppSettings: Codable {
    var autoUnlockEnabled: Bool = false
    var autoTypeEnabled: Bool = false
}

final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var value = AppSettings()

    private init() {
        load()
    }

    var fileURL: URL { AppPaths.settingsURL }

    /// 从包内读取配置，文件不存在时使用默认值。
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            value = AppSettings()
            return
        }
        value = decoded
    }

    /// 修改并立即写回包内。
    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&value)
        save()
    }

    /// 写入包内 settings.json。
    func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        AppPaths.prepare()
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            AppLog.write("save settings failed: \(error.localizedDescription)")
        }
    }
}
