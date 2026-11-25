import AppKit
import ServiceManagement

/// 菜单栏入口与全部用户操作。
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var delegate: AppDelegate?
    private let menu = NSMenu()
    private var hideWorkItem: DispatchWorkItem?
    private var menuIsOpen = false

    init(delegate: AppDelegate) {
        self.delegate = delegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "FaceUnlock")
            button.image?.isTemplate = true
            button.toolTip = "FaceUnlock"
        }
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = true
    }

    /// 显示菜单栏图标；传入延迟时，若期间没有打开菜单就自动隐藏。
    func show(autoHideAfter delay: TimeInterval? = nil) {
        statusItem.isVisible = true
        hideWorkItem?.cancel()
        hideWorkItem = nil
        AppLog.write("status icon shown (autoHide=\(delay.map { String(format: "%.0f", $0) } ?? "no"))")
        guard let delay else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.menuIsOpen else { return }
            self.statusItem.isVisible = false
            AppLog.write("status icon hidden")
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        hideWorkItem?.cancel()
        hideWorkItem = nil
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    /// 每次打开菜单时重建，保证状态实时。
    private func rebuild() {
        menu.removeAllItems()
        guard let delegate else { return }

        addInfo(delegate.profileSummary)
        addInfo(delegate.lastStatus)
        menu.addItem(.separator())

        add("录入人脸…", #selector(AppDelegate.showEnrollment), delegate)
        add("测试识别…", #selector(AppDelegate.showTest), delegate, key: "t")
        addSensitivityMenu()
        menu.addItem(.separator())

        addCheck(
            "锁屏自动识别",
            #selector(AppDelegate.toggleAutoUnlock),
            delegate,
            on: SettingsStore.shared.value.autoUnlockEnabled
        )

        let hasPassword = CredentialStore.hasPassword
        addCheck(
            hasPassword ? "自动输入密码" : "自动输入密码（先设置密码）",
            #selector(AppDelegate.toggleAutoType),
            delegate,
            on: SettingsStore.shared.value.autoTypeEnabled,
            enabled: hasPassword
        )
        add("设置登录密码…", #selector(AppDelegate.setPassword), delegate)
        add("清除登录密码", #selector(AppDelegate.clearPassword), delegate, enabled: hasPassword)
        menu.addItem(.separator())

        add("打开数据目录", #selector(AppDelegate.openDataDirectory), delegate)
        add("清除全部数据并退出…", #selector(AppDelegate.clearAllData), delegate)
        menu.addItem(.separator())

        add("摄像头权限：\(delegate.cameraPermissionText)", #selector(AppDelegate.handleCameraPermission), delegate)
        add("辅助功能：\(delegate.accessibilityPermissionText)", #selector(AppDelegate.handleAccessibilityPermission), delegate)
        addCheck(
            "开机自启",
            #selector(AppDelegate.toggleLaunchAtLogin),
            delegate,
            on: delegate.launchAtLoginEnabled
        )
        menu.addItem(.separator())

        add("退出 FaceUnlock", #selector(NSApplication.terminate(_:)), nil, key: "q")
    }

    /// 识别灵敏度子菜单：直接设置匹配阈值。
    private func addSensitivityMenu() {
        guard let delegate else { return }
        let item = NSMenuItem(title: "识别灵敏度", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = delegate.store.profile?.threshold ?? 0
        let presets: [(String, Float)] = [
            ("严格 · 0.45", 0.45),
            ("标准 · 0.55", 0.55),
            ("宽松 · 0.65", 0.65)
        ]
        for (title, value) in presets {
            let sub = NSMenuItem(
                title: title,
                action: #selector(AppDelegate.setSensitivity(_:)),
                keyEquivalent: ""
            )
            sub.target = delegate
            sub.representedObject = NSNumber(value: value)
            sub.state = abs(current - value) < 0.005 ? .on : .off
            submenu.addItem(sub)
        }
        item.submenu = submenu
        item.isEnabled = delegate.store.hasProfile
        menu.addItem(item)
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func add(
        _ title: String,
        _ action: Selector,
        _ target: AnyObject?,
        key: String = "",
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func addCheck(
        _ title: String,
        _ action: Selector,
        _ target: AnyObject?,
        on: Bool,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.state = on ? .on : .off
        item.isEnabled = enabled
        menu.addItem(item)
    }
}
