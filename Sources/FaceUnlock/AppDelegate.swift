import AppKit
import AVFoundation
import ServiceManagement

/// App 生命周期与菜单动作的实现。
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = EnrollmentStore()
    let engine = FaceEngine()

    private let unlockCamera = CameraController()
    private lazy var unlockController = UnlockController(
        camera: unlockCamera,
        engine: engine,
        store: store
    )

    private var statusBar: StatusBarController?
    private let lockMonitor = LockScreenMonitor()
    private var windowController: CameraWindowController?

    var lastStatus = "待机"
    var profileSummary: String {
        guard let profile = store.profile else { return "未录入人脸" }
        return String(
            format: "已录入 · 阈值 %.2f · 原型 %d 个",
            profile.threshold,
            profile.prototypes.count
        )
    }

    var cameraPermissionText: String {
        switch CameraController.authorizationStatus {
        case .authorized:
            return "已授权"
        case .denied:
            return "已拒绝"
        case .restricted:
            return "受限"
        case .notDetermined:
            return "未请求"
        @unknown default:
            return "未知"
        }
    }

    /// macOS 27 起「辅助功能」在中文系统里改名为「无障碍」。
    private var isMacOS27OrLater: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    private var privacySecurityName: String {
        isMacOS27OrLater ? "隐私与安全" : "隐私与安全性"
    }

    private var accessibilityPaneName: String {
        isMacOS27OrLater ? "无障碍" : "辅助功能"
    }

    var accessibilityPermissionText: String {
        "\(accessibilityPaneName)：\(PasswordTyper.isTrusted ? "已授权" : "未授权")"
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.local.faceunlock.login.plist")
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
            || FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ready = AppPaths.prepare()
        AppLog.write(
            "launched · bundle=\(Bundle.main.bundlePath) · dataWritable=\(ready) · axTrusted=\(PasswordTyper.isTrusted) · camera=\(CameraController.authorizationStatus.rawValue)"
        )
        if SettingsStore.shared.value.autoUnlockEnabled,
           CameraController.authorizationStatus == .notDetermined {
            Task { _ = await CameraController.requestAccess() }
        }

        statusBar = StatusBarController(delegate: self)

        if SettingsStore.shared.value.autoUnlockEnabled && store.hasProfile {
            statusBar?.show(autoHideAfter: 3)
        } else {
            statusBar?.show()
        }

        unlockController.onStatusChange = { [weak self] text in
            self?.lastStatus = text
        }
        unlockController.onScanningChange = { [weak self] scanning in
            AppLog.write(scanning ? "menu state: scanning" : "menu state: idle")
            if scanning {
                self?.statusBar?.show()
            }
        }

        lockMonitor.onLock = { [weak self] in
            guard let self else { return }
            self.statusBar?.show()
            guard self.windowController == nil else { return }
            self.unlockController.handleLock()
        }
        lockMonitor.onWake = { [weak self] in
            guard let self else { return }
            self.statusBar?.show()
            guard self.windowController == nil else { return }
            self.unlockController.handleWake()
        }
        lockMonitor.onDisplaySleep = { [weak self] in
            self?.unlockController.handleDisplaySleep()
        }
        lockMonitor.onUnlock = { [weak self] in
            guard let self else { return }
            self.unlockController.handleUnlock()
            if SettingsStore.shared.value.autoUnlockEnabled && self.store.hasProfile {
                self.statusBar?.show(autoHideAfter: 3)
            }
        }
        lockMonitor.start()

        // 预配置相机，减少锁屏后第一次扫描的启动延迟
        if SettingsStore.shared.value.autoUnlockEnabled,
           CameraController.authorizationStatus == .authorized {
            unlockCamera.prepare()
        }

        // 更新二进制后无障碍权限会失效，主动弹一次系统授权提示
        if SettingsStore.shared.value.autoTypeEnabled && !PasswordTyper.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                AppLog.write("accessibility not trusted, requesting system prompt")
                PasswordTyper.requestAccess()
            }
        }

        if Bundle.main.bundlePath.contains("AppTranslocation") {
            showAlert(
                "请先移动 App",
                "当前 App 运行在系统只读的临时目录里，无法写入包内数据。请把 FaceUnlock.app 拖到 /Applications 或 ~/Applications 后再打开。",
                style: .warning
            )
        } else if !ready {
            showAlert(
                "数据目录不可写",
                "无法在 App 包内创建 Contents/Data。请确认 App 位于可写目录（推荐 ~/Applications），且没有只读限制。",
                style: .warning
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lockMonitor.stop()
        unlockCamera.stop()
    }

    /// 再次打开 App 时把菜单栏图标叫回来，方便进入设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SettingsStore.shared.value.autoUnlockEnabled && store.hasProfile {
            statusBar?.show(autoHideAfter: 3)
        } else {
            statusBar?.show()
        }
        return true
    }

    /// 关闭窗口状态恢复，避免在 ~/Library/Saved Application State 留下文件。
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    // MARK: - 窗口

    @objc func showEnrollment() {
        openCameraWindow(mode: .enroll)
    }

    @objc func showTest() {
        openCameraWindow(mode: .test)
    }

    /// 打开录入或测试窗口，窗口已存在时直接前置。
    private func openCameraWindow(mode: CameraWindowController.Mode) {
        guard ensureDataDirectory() else { return }
        if let existing = windowController {
            existing.present()
            return
        }
        withCameraPermission { [weak self] in
            guard let self else { return }
            let controller = CameraWindowController(mode: mode, store: self.store)
            controller.onClose = { [weak self] in
                self?.windowController = nil
            }
            self.windowController = controller
            controller.present()
        }
    }

    private func ensureDataDirectory() -> Bool {
        guard AppPaths.prepare() else {
            showAlert("数据目录不可写", "请把 App 放到可写目录（推荐 ~/Applications）后再试。", style: .warning)
            return false
        }
        return true
    }

    private func withCameraPermission(_ action: @escaping () -> Void) {
        switch CameraController.authorizationStatus {
        case .authorized:
            action()
        case .notDetermined:
            Task {
                let granted = await CameraController.requestAccess()
                await MainActor.run {
                    if granted {
                        action()
                    } else {
                        self.showAlert(
                            "摄像头未授权",
                            "请到 系统设置 → \(self.privacySecurityName) → 摄像头 中勾选 FaceUnlock。",
                            style: .warning
                        )
                        self.openCameraSettings()
                    }
                }
            }
        default:
            showAlert(
                "摄像头不可用",
                "请到 系统设置 → \(privacySecurityName) → 摄像头 中勾选 FaceUnlock 后重试。",
                style: .warning
            )
            openCameraSettings()
        }
    }

    // MARK: - 开关

    @objc func toggleAutoUnlock() {
        let enabled = SettingsStore.shared.value.autoUnlockEnabled
        if !enabled {
            guard store.hasProfile else {
                showAlert("尚未录入人脸", "请先「录入人脸」，再开启锁屏自动识别。", style: .warning)
                return
            }
            switch CameraController.authorizationStatus {
            case .authorized:
                break
            case .notDetermined:
                Task { _ = await CameraController.requestAccess() }
            default:
                showAlert(
                    "摄像头未授权",
                    "锁屏识别需要摄像头权限，请到 系统设置 → \(privacySecurityName) → 摄像头 中勾选 FaceUnlock。",
                    style: .warning
                )
                openCameraSettings()
                return
            }
        }
        SettingsStore.shared.update { $0.autoUnlockEnabled.toggle() }
        lastStatus = SettingsStore.shared.value.autoUnlockEnabled
            ? "锁屏自动识别已开启"
            : "锁屏自动识别已关闭"
        if !SettingsStore.shared.value.autoUnlockEnabled {
            statusBar?.show()
        }
        AppLog.write(lastStatus)
    }

    @objc func toggleAutoType() {
        let enabled = SettingsStore.shared.value.autoTypeEnabled
        if !enabled {
            guard CredentialStore.hasPassword else {
                showAlert("尚未设置密码", "请先「设置登录密码」，再开启自动输入。", style: .warning)
                return
            }
            guard PasswordTyper.isTrusted else {
                showAlert(
                    "需要\(accessibilityPaneName)权限",
                    "自动输入密码需要在 系统设置 → \(privacySecurityName) → \(accessibilityPaneName) 中勾选 FaceUnlock。勾选后再回来开启此开关。",
                    style: .warning
                )
                PasswordTyper.requestAccess()
                openAccessibilitySettings()
                return
            }
        }
        SettingsStore.shared.update { $0.autoTypeEnabled.toggle() }
        lastStatus = SettingsStore.shared.value.autoTypeEnabled
            ? "自动输入密码已开启"
            : "自动输入密码已关闭（仅试运行）"
        AppLog.write(lastStatus)
    }

    @objc func toggleLaunchAtLogin() {
        if launchAtLoginEnabled {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgent()
            lastStatus = "已关闭开机自启"
        } else {
            // 先清理可能残留的同 bundle 注册
            try? SMAppService.mainApp.unregister()
            do {
                try SMAppService.mainApp.register()
                lastStatus = "已开启开机自启"
            } catch {
                AppLog.write("SMAppService failed: \(error.localizedDescription), falling back to LaunchAgent")
                if installLaunchAgent() {
                    lastStatus = "已开启开机自启（LaunchAgent）"
                } else {
                    showAlert(
                        "开机自启设置失败",
                        "\(error.localizedDescription)\n已尝试 LaunchAgent 兜底但仍失败，请检查 ~/Library/LaunchAgents 权限。",
                        style: .warning
                    )
                }
            }
        }
        AppLog.write(lastStatus)
    }

    /// 用 LaunchAgent 兜底，绕过 ad-hoc 签名下 SMAppService 的权限限制。
    private func installLaunchAgent() -> Bool {
        let executable = Bundle.main.executablePath
            ?? "/Applications/FaceUnlock.app/Contents/MacOS/FaceUnlock"
        let plist: [String: Any] = [
            "Label": "com.local.faceunlock.login",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
        let directory = launchAgentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else {
            return false
        }
        do {
            try data.write(to: launchAgentURL, options: .atomic)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(getuid())", launchAgentURL.path]
            try? process.run()
            process.waitUntilExit()
            return true
        } catch {
            AppLog.write("install LaunchAgent failed: \(error.localizedDescription)")
            return false
        }
    }

    private func removeLaunchAgent() {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", launchAgentURL.path]
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    // MARK: - 密码

    @objc func setPassword() {
        guard ensureDataDirectory() else { return }

        let alert = NSAlert()
        alert.messageText = "设置登录密码"
        alert.informativeText = """
        密码会用 AES-GCM 加密后写入 App 包内，密钥也在包内。
        这只能防止明文直读，不能防御本机上有权限的进程，请确认你接受这一风险。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Mac 登录密码"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !field.stringValue.isEmpty else {
            showAlert("密码为空", "没有保存任何内容。", style: .warning)
            return
        }
        do {
            try CredentialStore.savePassword(field.stringValue)
            lastStatus = "登录密码已加密保存到包内"
        } catch {
            showAlert("保存失败", error.localizedDescription, style: .critical)
        }
    }

    @objc func clearPassword() {
        guard CredentialStore.hasPassword else { return }
        let alert = NSAlert()
        alert.messageText = "清除登录密码？"
        alert.informativeText = "会删除包内的密码密文，并自动关闭「自动输入密码」。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        CredentialStore.deletePassword()
        SettingsStore.shared.update { $0.autoTypeEnabled = false }
        lastStatus = "登录密码已清除"
    }

    // MARK: - 数据目录与卸载

    @objc func openDataDirectory() {
        guard ensureDataDirectory() else { return }
        NSWorkspace.shared.open(AppPaths.dataDirectory)
    }

    @objc func clearAllData() {
        let alert = NSAlert()
        alert.messageText = "清除全部数据并退出？"
        alert.informativeText = """
        将删除：
        · App 包内的人脸模板、密码密文、配置、日志
        · 系统钥匙串中的加密密钥
        · 开机自启注册

        之后把 FaceUnlock.app 拖到废纸篓即可。此操作不可恢复。
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "清除并退出")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        windowController?.close()
        lockMonitor.stop()
        unlockCamera.stop()
        try? SMAppService.mainApp.unregister()
        AppLog.suspend()
        DataWiper.clearAll()
        NSApp.terminate(nil)
    }

    // MARK: - 权限

    @objc func handleCameraPermission() {
        switch CameraController.authorizationStatus {
        case .authorized:
            showAlert("摄像头已授权", "FaceUnlock 可以在需要时打开摄像头。")
        case .notDetermined:
            Task { _ = await CameraController.requestAccess() }
        default:
            openCameraSettings()
        }
    }

    @objc func handleAccessibilityPermission() {
        AppLog.write("accessibility pane requested, trusted=\(PasswordTyper.isTrusted)")
        if PasswordTyper.isTrusted {
            showAlert("\(accessibilityPaneName)已授权", "自动输入密码可以正常工作。")
        } else {
            PasswordTyper.requestAccess()
            openAccessibilitySettings()
        }
    }

    /// 设置识别阈值：严格 0.45 / 标准 0.55 / 宽松 0.65。
    @objc func setSensitivity(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber, store.hasProfile else { return }
        store.updateThreshold(number.floatValue)
        lastStatus = String(format: "识别阈值已设为 %.2f", number.floatValue)
        AppLog.write(lastStatus)
    }

    private func openCameraSettings() {
        let path = isMacOS27OrLater
            ? "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        if let url = URL(string: path) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAccessibilitySettings() {
        let path = isMacOS27OrLater
            ? "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: path) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 提示

    private func showAlert(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
