import CoreGraphics
import CoreVideo
import Foundation

/// 锁屏自动识别控制器：扫描、比对、决定是否输入密码。
final class UnlockController {
    private let camera: CameraController
    private let engine: FaceEngine
    private let store: EnrollmentStore

    var onStatusChange: ((String) -> Void)?
    var onScanningChange: ((Bool) -> Void)?

    private var scanning = false
    private var busy = false
    private var frames = 0
    private var matchCount = 0
    private var bestDistance = Float.greatestFiniteMagnitude
    private var goodStreak = 0
    private var strongMatch = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var attemptsThisLock = 0
    private var lastLockEvent = Date.distantPast

    init(camera: CameraController, engine: FaceEngine, store: EnrollmentStore) {
        self.camera = camera
        self.engine = engine
        self.store = store
    }

    /// 显示器是否处于休眠状态。
    private static var displayIsAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 锁屏事件入口。显示器已休眠时不做无意义的扫描，等唤醒后再扫。
    func handleLock() {
        guard SettingsStore.shared.value.autoUnlockEnabled else {
            AppLog.write("lock: auto unlock disabled, skip")
            return
        }
        guard let profile = store.profile else {
            AppLog.write("lock: no profile, skip")
            return
        }
        guard LockScreenMonitor.isScreenLocked else {
            AppLog.write("lock: not actually locked, skip")
            return
        }
        guard !scanning else { return }
        guard !Self.displayIsAsleep else {
            AppLog.write("lock: display asleep, wait for wake")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastLockEvent) > 3 else { return }
        lastLockEvent = now
        guard attemptsThisLock < 5 else {
            AppLog.write("lock: attempt limit reached")
            return
        }
        attemptsThisLock += 1
        beginScan(profile: profile)
    }

    /// 唤醒事件入口：如果仍处于锁屏，取消旧扫描并重新扫一次。
    func handleWake() {
        guard SettingsStore.shared.value.autoUnlockEnabled else { return }
        guard let profile = store.profile else { return }
        guard LockScreenMonitor.isScreenLocked else { return }

        AppLog.write("wake: still locked, rescan scheduled")
        cancelScan(reason: "display wake")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            guard SettingsStore.shared.value.autoUnlockEnabled,
                  LockScreenMonitor.isScreenLocked,
                  !Self.displayIsAsleep,
                  !self.scanning else { return }
            guard self.attemptsThisLock < 5 else {
                AppLog.write("wake: attempt limit reached")
                return
            }
            self.attemptsThisLock += 1
            self.beginScan(profile: profile)
        }
    }

    /// 显示器休眠：立刻停止扫描，避免在熄屏状态下匹配和输入。
    func handleDisplaySleep() {
        guard scanning else { return }
        cancelScan(reason: "display sleep")
    }

    /// 解锁事件入口：立即停止扫描并重置尝试次数。
    func handleUnlock() {
        attemptsThisLock = 0
        guard scanning else { return }
        goodStreak = 0
        matchCount = 0
        strongMatch = false
        finish(profile: nil, reason: "屏幕已解锁")
    }

    /// 供菜单手动触发的试运行（不要求锁屏）。
    func manualTest() {
        guard let profile = store.profile else {
            onStatusChange?("尚未录入人脸")
            return
        }
        guard !scanning else { return }
        beginScan(profile: profile)
    }

    var isScanning: Bool { scanning }

    private func beginScan(profile: FaceProfile) {
        scanning = true
        busy = false
        frames = 0
        matchCount = 0
        goodStreak = 0
        strongMatch = false
        bestDistance = .greatestFiniteMagnitude
        onScanningChange?(true)
        onStatusChange?("扫描中…")
        AppLog.write(
            "scan start (threshold \(profile.threshold), axTrusted=\(PasswordTyper.isTrusted), displayAsleep=\(Self.displayIsAsleep), camera=\(CameraController.authorizationStatus.rawValue))"
        )

        camera.onFrame = { [weak self] pixelBuffer in
            DispatchQueue.main.async {
                self?.handleFrame(pixelBuffer, profile: profile)
            }
        }
        camera.onError = { [weak self] message in
            self?.onStatusChange?("摄像头错误：\(message)")
            AppLog.write("camera error: \(message)")
        }
        camera.start()

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.scanning else { return }
            self.finish(profile: profile, reason: "扫描超时")
        }
        timeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, profile: FaceProfile) {
        guard scanning, !busy else { return }
        busy = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let faces = try await self.engine.detect(in: pixelBuffer)
                guard faces.count == 1, let face = faces.first else { return }
                guard face.boundingBox.cgRect.width > 0.12 else { return }

                let vector = try await self.engine.featureVector(for: face, in: pixelBuffer)
                let distance = profile.prototypes
                    .map { FaceEngine.distance(vector, $0) }
                    .min() ?? .greatestFiniteMagnitude
                guard self.scanning else { return }

                self.frames += 1
                self.bestDistance = min(self.bestDistance, distance)
                if distance <= profile.threshold {
                    self.goodStreak += 1
                    self.matchCount += 1
                } else {
                    self.goodStreak = 0
                }
                self.onStatusChange?(
                    "扫描中 \(self.frames) 帧 · 距离 \(String(format: "%.3f", self.bestDistance))"
                )

                // 单帧明显低于阈值就直接解锁，否则等第二帧连续命中
                if distance <= profile.threshold * 0.9 {
                    self.strongMatch = true
                    self.finish(profile: profile, reason: "强匹配")
                } else if self.goodStreak >= 2 {
                    self.finish(profile: profile, reason: "连续匹配")
                }
            } catch {
                AppLog.write("scan frame error: \(error.localizedDescription)")
            }
        }
    }

    private func cancelScan(reason: String) {
        guard scanning else { return }
        scanning = false
        busy = false
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        camera.onFrame = nil
        camera.stop()
        engine.releaseResources()
        onScanningChange?(false)
        AppLog.write("scan cancelled (\(reason))")
    }

    private func finish(profile: FaceProfile?, reason: String) {
        guard scanning else { return }
        scanning = false
        busy = false
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        camera.onFrame = nil
        camera.stop()
        engine.releaseResources()
        onScanningChange?(false)

        let effective = profile ?? store.profile
        let threshold = effective?.threshold ?? 0
        // 强匹配、两帧连续、两帧累计，或多帧中至少一帧命中，都算匹配
        let matched = strongMatch
            || goodStreak >= 2
            || matchCount >= 2
            || (frames >= 6 && matchCount >= 1 && bestDistance <= threshold)
        let summary = String(
            format: "%@ · %d 帧 · 命中 %d · 距离 %.3f / 阈值 %.2f · %@",
            matched ? "匹配成功" : "未匹配",
            frames,
            matchCount,
            bestDistance,
            threshold,
            reason
        )
        onStatusChange?(summary)
        AppLog.write(summary)

        guard matched else { return }
        guard LockScreenMonitor.isScreenLocked else {
            AppLog.write("matched but screen is not locked, skip typing")
            return
        }
        guard !Self.displayIsAsleep else {
            AppLog.write("matched but display asleep, skip typing")
            return
        }
        guard SettingsStore.shared.value.autoTypeEnabled else {
            AppLog.write("dry run: matched, password typing disabled")
            return
        }
        guard let password = CredentialStore.loadPassword(), !password.isEmpty else {
            AppLog.write("no stored password")
            return
        }
        guard PasswordTyper.isTrusted else {
            AppLog.write("typing failed: accessibility permission missing")
            onStatusChange?("匹配成功，但缺少无障碍权限")
            return
        }
        guard PasswordTyper.type(password, submit: true) else {
            AppLog.write("typing failed: could not create key events")
            return
        }
        AppLog.write("password typed and submitted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if LockScreenMonitor.isScreenLocked {
                AppLog.write("typing did not unlock (still locked)")
                self?.onStatusChange?("已输入密码但未解锁，请检查密码是否正确")
            } else {
                AppLog.write("unlock confirmed")
                self?.onStatusChange?("人脸解锁成功")
            }
        }
    }
}
