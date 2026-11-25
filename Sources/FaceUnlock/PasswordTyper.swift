import ApplicationServices
import CoreGraphics
import Foundation

/// 用 CGEvent 把文本注入当前焦点，用于锁屏密码输入。
enum PasswordTyper {
    /// 当前进程是否拥有辅助功能权限。
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 弹出系统授权提示，把本 App 加入辅助功能列表。
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 逐字符输入文本，可选回车提交。
    @discardableResult
    static func type(_ text: String, submit: Bool) -> Bool {
        guard isTrusted else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for character in text {
            var units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }

        if submit {
            usleep(50_000)
            postReturn(source: source)
        }
        return true
    }

    /// 发送回车键。
    private static func postReturn(source: CGEventSource) {
        let keyCode: CGKeyCode = 0x24
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}
