import AppKit
import CoreGraphics

/// 监听锁屏、唤醒与显示器休眠事件。
final class LockScreenMonitor {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?
    var onDisplaySleep: (() -> Void)?
    var onWake: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    /// 通过 CGSession 判断当前是否处于锁屏状态。
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                AppLog.write("event: screen locked")
                self?.onLock?()
            }
        )
        observers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                AppLog.write("event: screen unlocked")
                self?.onUnlock?()
            }
        )

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                AppLog.write("event: display slept")
                self?.onDisplaySleep?()
            }
        )
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                AppLog.write("event: wake")
                self?.onWake?()
            }
        )
    }

    func stop() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            distributed.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        observers.removeAll()
    }
}
