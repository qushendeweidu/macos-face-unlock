import Foundation

/// 轻量文件日志：写在 App 包内 Contents/Data/Logs，删除 App 即彻底清除。
enum AppLog {
    private static let queue = DispatchQueue(label: "com.local.faceunlock.log")
    private static var isSuspended = false

    static var fileURL: URL {
        AppPaths.logsDirectory.appendingPathComponent("FaceUnlock.log")
    }

    /// 追加一条带时间戳的日志，同时输出到 Console。
    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            guard !isSuspended, let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(
                at: AppPaths.logsDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        NSLog("[FaceUnlock] %@", message)
    }

    /// 卸载清理前暂停写入，避免删除目录后又把日志写回来。
    static func suspend() {
        queue.sync {
            isSuspended = true
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
