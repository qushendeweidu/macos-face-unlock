import Foundation

/// 标准 macOS 数据路径：App 包保持只读，数据放 Application Support，日志放 Logs。
enum AppPaths {
    /// 当前 App 包的根目录。
    static let bundleURL: URL = {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : url.deletingLastPathComponent()
    }()

    static var dataDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("FaceUnlock", isDirectory: true)
    }

    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FaceUnlock", isDirectory: true)
    }

    static var profileURL: URL {
        dataDirectory.appendingPathComponent("profile.bin")
    }

    static var credentialURL: URL {
        dataDirectory.appendingPathComponent("credential.bin")
    }

    static var keyURL: URL {
        dataDirectory.appendingPathComponent("key.bin")
    }

    static var settingsURL: URL {
        dataDirectory.appendingPathComponent("settings.json")
    }

    /// 创建数据与日志目录，并迁移旧版放在 App 包内或同级 Data 的文件。
    @discardableResult
    static func prepare() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dataDirectory.path
            )
            migrateLegacyDataIfNeeded()
            return true
        } catch {
            return false
        }
    }

    static var isWritable: Bool {
        FileManager.default.isWritableFile(atPath: dataDirectory.path)
    }

    /// 把旧版包内数据复制到标准位置，只复制缺失文件，不删除旧文件。
    private static func migrateLegacyDataIfNeeded() {
        let fileManager = FileManager.default
        var legacyDirectories: [URL] = []

        let parent = bundleURL.deletingLastPathComponent()
        if parent.lastPathComponent == "FaceUnlock" {
            legacyDirectories.append(parent.appendingPathComponent("Data", isDirectory: true))
        }
        legacyDirectories.append(bundleURL.appendingPathComponent("Contents/Data", isDirectory: true))

        for legacy in legacyDirectories {
            guard fileManager.fileExists(atPath: legacy.path) else { continue }

            for name in ["key.bin", "profile.bin", "credential.bin", "settings.json"] {
                let source = legacy.appendingPathComponent(name)
                let destination = dataDirectory.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: source.path),
                      !fileManager.fileExists(atPath: destination.path) else {
                    continue
                }
                try? fileManager.copyItem(at: source, to: destination)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
            }

            let sourceLog = legacy.appendingPathComponent("Logs/FaceUnlock.log")
            let destinationLog = logsDirectory.appendingPathComponent("FaceUnlock.log")
            if fileManager.fileExists(atPath: sourceLog.path),
               !fileManager.fileExists(atPath: destinationLog.path) {
                try? fileManager.copyItem(at: sourceLog, to: destinationLog)
            }
        }
    }
}
