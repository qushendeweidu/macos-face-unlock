import CryptoKit
import Foundation
import Security

enum StorageError: LocalizedError {
    case keychain(OSStatus)
    case corruptedData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败（\(status)）：\(message)"
        case .corruptedData:
            return "本地数据损坏"
        }
    }
}

/// 人脸模板：只保存特征向量，不保存任何图像。
struct FaceProfile: Codable {
    var prototypes: [[Float]]
    var threshold: Float
    var createdAt: Date
}

/// 包内密钥：与密文一起放在 Contents/Data，保证重编译不弹钥匙串、删除即干净。
/// 注意：这只能防止明文直读，不能防御本机上有权限的进程。
enum LocalKeyProvider {
    private static let size = 32

    static func key() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: AppPaths.keyURL), data.count == size {
            return SymmetricKey(data: data)
        }

        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }

        let keyData = Data(bytes)
        AppPaths.prepare()
        try keyData.write(to: AppPaths.keyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.keyURL.path
        )
        AppLog.write("local key created in bundle")
        return SymmetricKey(data: keyData)
    }
}

/// 旧版本密钥：只用于一次性迁移，迁移完成后删除该钥匙串条目。
enum LegacyKeychainKeyProvider {
    private static let service = "com.local.faceunlock"
    private static let account = "storage-key"

    static func key() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 人脸模板存储：AES-GCM 加密后写入 App 包内。
final class EnrollmentStore {
    private(set) var profile: FaceProfile?

    private var fileURL: URL { AppPaths.profileURL }

    init() {
        AppPaths.prepare()
        migrateLegacyDataIfNeeded()
        load()
    }

    var hasProfile: Bool { profile != nil }

    /// 读取并解密模板。
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profile = nil
            return
        }
        do {
            let key = try LocalKeyProvider.key()
            let sealed = try Data(contentsOf: fileURL)
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plaintext = try AES.GCM.open(box, using: key)
            let decoded = try JSONDecoder().decode(FaceProfile.self, from: plaintext)
            profile = decoded
            AppLog.write(
                "profile loaded: \(decoded.prototypes.count) prototypes, threshold \(decoded.threshold)"
            )
        } catch {
            profile = nil
            AppLog.write("load profile failed: \(error.localizedDescription)")
        }
    }

    /// 加密并保存模板。
    func save(_ profile: FaceProfile) throws {
        let key = try LocalKeyProvider.key()
        let plaintext = try JSONEncoder().encode(profile)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw StorageError.corruptedData }
        AppPaths.prepare()
        try combined.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        self.profile = profile
        AppLog.write("profile saved: \(profile.prototypes.count) prototypes, threshold \(profile.threshold)")
    }

    /// 只更新阈值，保留已录入模板。
    func updateThreshold(_ threshold: Float) {
        guard var current = profile else { return }
        current.threshold = threshold
        try? save(current)
    }

    /// 删除模板文件。
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        profile = nil
        AppLog.write("profile cleared")
    }

    /// 把旧版钥匙串密钥加密的数据迁移到包内密钥，然后删除钥匙串条目。
    private func migrateLegacyDataIfNeeded() {
        let hasOldData = FileManager.default.fileExists(atPath: AppPaths.profileURL.path)
            || FileManager.default.fileExists(atPath: AppPaths.credentialURL.path)
        guard hasOldData, !FileManager.default.fileExists(atPath: AppPaths.keyURL.path) else {
            return
        }

        AppLog.write("legacy keychain data found, migrating")
        guard let legacyKey = LegacyKeychainKeyProvider.key() else {
            AppLog.write("legacy key unavailable, removing old encrypted files")
            try? FileManager.default.removeItem(at: AppPaths.profileURL)
            try? FileManager.default.removeItem(at: AppPaths.credentialURL)
            return
        }

        do {
            let newKey = try LocalKeyProvider.key()
            if let sealed = try? Data(contentsOf: AppPaths.profileURL) {
                let box = try AES.GCM.SealedBox(combined: sealed)
                let plaintext = try AES.GCM.open(box, using: legacyKey)
                let reSealed = try AES.GCM.seal(plaintext, using: newKey)
                if let combined = reSealed.combined {
                    try combined.write(to: AppPaths.profileURL, options: .atomic)
                }
            }
            if let sealed = try? Data(contentsOf: AppPaths.credentialURL) {
                let box = try AES.GCM.SealedBox(combined: sealed)
                let plaintext = try AES.GCM.open(box, using: legacyKey)
                let reSealed = try AES.GCM.seal(plaintext, using: newKey)
                if let combined = reSealed.combined {
                    try combined.write(to: AppPaths.credentialURL, options: .atomic)
                }
            }
            LegacyKeychainKeyProvider.delete()
            AppLog.write("migration complete")
        } catch {
            AppLog.write("migration failed: \(error.localizedDescription)")
        }
    }
}

/// 登录密码存储：AES-GCM 加密后写入 App 包内，不落明文。
enum CredentialStore {
    private static var fileURL: URL { AppPaths.credentialURL }

    static var hasPassword: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 保存或覆盖登录密码密文。
    static func savePassword(_ password: String) throws {
        let key = try LocalKeyProvider.key()
        let sealed = try AES.GCM.seal(Data(password.utf8), using: key)
        guard let combined = sealed.combined else { throw StorageError.corruptedData }
        AppPaths.prepare()
        try combined.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        AppLog.write("password encrypted into bundle data")
    }

    /// 读取并解密登录密码。
    static func loadPassword() -> String? {
        guard let sealed = try? Data(contentsOf: fileURL),
              let key = try? LocalKeyProvider.key(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return String(data: plaintext, encoding: .utf8)
    }

    /// 删除密码密文。
    static func deletePassword() {
        try? FileManager.default.removeItem(at: fileURL)
        AppLog.write("password removed")
    }
}

/// 卸载清理：删除标准数据、日志、旧版包内残留和钥匙串条目。
enum DataWiper {
    static func clearAll() {
        LegacyKeychainKeyProvider.delete()

        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            AppPaths.dataDirectory,
            AppPaths.logsDirectory,
            home.appendingPathComponent("Library/Logs/FaceUnlock.log"),
            home.appendingPathComponent("Library/Preferences/com.local.faceunlock.plist"),
            home.appendingPathComponent("Library/LaunchAgents/com.local.faceunlock.login.plist"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Data")
        ]

        // 旧版把数据放在 App 同级的 Data 目录
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        if parent.lastPathComponent == "FaceUnlock" {
            paths.append(parent.appendingPathComponent("Data", isDirectory: true))
        }

        for path in paths {
            try? FileManager.default.removeItem(at: path)
        }
    }
}
