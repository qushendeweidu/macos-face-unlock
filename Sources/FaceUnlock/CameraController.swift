import AVFoundation
import CoreVideo
import Foundation

/// 按需启动的摄像头采集器：640×480、丢弃迟到帧，扫描结束立即关闭。
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.local.faceunlock.camera")
    private var configured = false

    /// 每一帧回调（在相机串行队列上执行）。
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// 配置失败回调（在主线程执行）。
    var onError: ((String) -> Void)?

    /// 当前摄像头授权状态。
    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// 请求摄像头授权。
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// 只配置会话、不启动采集，用于缩短首次扫描的启动时间。
    func prepare() {
        queue.async { [weak self] in
            guard let self, !self.configured else { return }
            self.configured = self.configureSession()
        }
    }

    /// 在后台队列启动会话，避免阻塞主线程。
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                guard self.configureSession() else { return }
                self.configured = true
            }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// 停止会话并关闭摄像头指示灯。
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// 构建采集会话，失败时回到主线程报告原因。
    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(for: .video) else {
            report("未找到可用摄像头")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            report("无法打开摄像头输入")
            return false
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)

        guard session.canAddOutput(output) else {
            report("无法添加视频输出")
            return false
        }
        session.addOutput(output)
        return true
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
