import AppKit
import CoreVideo
import Foundation

/// 录入 / 测试窗口：复用同一套相机与识别链路。
final class CameraWindowController: NSWindowController, NSWindowDelegate {
    enum Mode {
        case enroll
        case test
    }

    private let mode: Mode
    private let store: EnrollmentStore
    private let camera = CameraController()
    private let engine = FaceEngine()

    var onClose: (() -> Void)?

    private let previewView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let primaryButton = NSButton()

    private var captureStarted = false
    private var busy = false
    private var lastProcessed = Date.distantPast
    private var lastPreview = Date.distantPast
    private var samples: [[Float]] = []
    private var currentDistance: Float?
    private var generation = UUID()

    init(mode: Mode, store: EnrollmentStore) {
        self.mode = mode
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = mode == .enroll ? "录入人脸" : "测试识别"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
        startCamera()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 构建窗口内容：预览、状态、进度与按钮。
    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.layer?.cornerRadius = 8
        previewView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.stringValue = mode == .enroll
            ? "点击「开始录入」，缓慢左右转头，保持画面中只有你一人。"
            : "正对镜头，观察距离值。"

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 30
        progress.doubleValue = 0
        progress.isHidden = mode != .enroll

        primaryButton.bezelStyle = .rounded
        primaryButton.title = mode == .enroll ? "开始录入" : "用当前距离校准阈值"
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.keyEquivalent = "\r"
        primaryButton.isEnabled = mode == .enroll ? true : store.profile != nil

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeTapped))
        closeButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [primaryButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [previewView, statusLabel, progress, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            previewView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            previewView.heightAnchor.constraint(equalToConstant: 340),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
    }

    /// 显示窗口并激活 App。
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 启动相机并把帧派发到主线程处理。
    private func startCamera() {
        camera.onFrame = { [weak self] pixelBuffer in
            DispatchQueue.main.async {
                self?.process(pixelBuffer)
            }
        }
        camera.onError = { [weak self] message in
            self?.statusLabel.stringValue = "摄像头错误：\(message)"
            AppLog.write("camera error: \(message)")
        }
        camera.start()
        AppLog.write("preview camera started (\(mode == .enroll ? "enroll" : "test"))")
    }

    /// 每帧：刷新预览，按节奏做人脸检测与特征计算。
    private func process(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()

        // 预览限速到约 15fps，避免无意义的图像转换开销
        if now.timeIntervalSince(lastPreview) > 0.066,
           let cgImage = engine.previewImage(from: pixelBuffer) {
            lastPreview = now
            previewView.image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }

        guard now.timeIntervalSince(lastProcessed) > 0.09, !busy else { return }
        lastProcessed = now
        busy = true
        let currentGeneration = generation

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            guard self.generation == currentGeneration else { return }

            do {
                let faces = try await self.engine.detect(in: pixelBuffer)
                guard self.generation == currentGeneration else { return }
                guard faces.count == 1, let face = faces.first else {
                    self.statusLabel.stringValue = faces.isEmpty
                        ? "未检测到人脸"
                        : "检测到 \(faces.count) 张脸，请保持画面中只有你"
                    return
                }
                guard face.boundingBox.cgRect.width > 0.12 else {
                    self.statusLabel.stringValue = "离镜头近一点"
                    return
                }

                if self.mode == .enroll {
                    guard self.captureStarted else { return }
                    guard abs(face.yaw.converted(to: .degrees).value) <= 35 else {
                        self.statusLabel.stringValue = "转头幅度太大，慢一点"
                        return
                    }
                    let vector = try await self.engine.featureVector(for: face, in: pixelBuffer)
                    guard self.generation == currentGeneration, self.captureStarted else { return }
                    self.samples.append(vector)
                    self.progress.doubleValue = Double(self.samples.count)
                    self.statusLabel.stringValue = "已采集 \(self.samples.count) / 30 帧，继续缓慢转头"
                    if self.samples.count >= 30 {
                        self.finishEnrollment()
                    }
                } else {
                    guard let profile = self.store.profile else {
                        self.statusLabel.stringValue = "尚未录入人脸，请先录入"
                        return
                    }
                    let vector = try await self.engine.featureVector(for: face, in: pixelBuffer)
                    guard self.generation == currentGeneration else { return }
                    let distance = profile.prototypes
                        .map { FaceEngine.distance(vector, $0) }
                        .min() ?? .greatestFiniteMagnitude
                    self.currentDistance = distance
                    self.statusLabel.stringValue = String(
                        format: "距离 %.3f · 阈值 %.2f · 原型 %d 个",
                        distance,
                        profile.threshold,
                        profile.prototypes.count
                    )
                    self.primaryButton.isEnabled = true
                }
            } catch {
                self.statusLabel.stringValue = "识别出错：\(error.localizedDescription)"
            }
        }
    }

    /// 汇总样本：取靠近均值的前 8 个作为原型，并按样本内距离给出初始阈值。
    private func finishEnrollment() {
        captureStarted = false
        progress.isHidden = false

        let mean = FaceEngine.average(samples)
        let sorted = samples.sorted { FaceEngine.distance($0, mean) < FaceEngine.distance($1, mean) }
        let prototypes = Array(sorted.prefix(8))

        var intraMax: Float = 0
        for left in 0..<prototypes.count {
            for right in (left + 1)..<prototypes.count {
                intraMax = max(intraMax, FaceEngine.distance(prototypes[left], prototypes[right]))
            }
        }
        let threshold = min(max(intraMax * 1.6, 0.20), 0.90)

        let profile = FaceProfile(prototypes: prototypes, threshold: threshold, createdAt: Date())
        do {
            try store.save(profile)
            statusLabel.stringValue = String(
                format: "录入完成：%d 帧，%d 个原型，阈值 %.2f",
                samples.count,
                prototypes.count,
                threshold
            )
            primaryButton.title = "重新录入"
        } catch {
            statusLabel.stringValue = "保存失败：\(error.localizedDescription)"
            AppLog.write("save profile failed: \(error.localizedDescription)")
        }
        primaryButton.isEnabled = true
        samples.removeAll()
        progress.doubleValue = 0
    }

    @objc private func primaryTapped() {
        switch mode {
        case .enroll:
            samples.removeAll()
            captureStarted = true
            progress.doubleValue = 0
            statusLabel.stringValue = "开始采集，请缓慢左右转头"
            primaryButton.isEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.captureStarted else { return }
                self.captureStarted = false
                self.primaryButton.isEnabled = true
                self.statusLabel.stringValue = "采集超时，只拿到 \(self.samples.count) 帧，请重试"
            }
        case .test:
            guard let distance = currentDistance, let profile = store.profile else { return }
            let threshold = min(max(distance * 1.25, 0.05), 0.95)
            store.updateThreshold(threshold)
            statusLabel.stringValue = String(
                format: "阈值已校准为 %.2f（当前距离 %.3f，原阈值 %.2f）",
                threshold,
                distance,
                profile.threshold
            )
        }
    }

    @objc private func closeTapped() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        generation = UUID()
        captureStarted = false
        camera.onFrame = nil
        camera.stop()
        engine.releaseResources()
        AppLog.write("preview camera stopped")
        onClose?()
    }
}
