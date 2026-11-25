import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

enum FaceEngineError: LocalizedError {
    case cropFailed
    case unsupportedElementType

    var errorDescription: String? {
        switch self {
        case .cropFailed:
            return "人脸裁剪失败"
        case .unsupportedElementType:
            return "不支持的特征数据类型"
        }
    }
}

/// Vision 封装：人脸检测、对齐裁剪、特征向量与距离计算。
final class FaceEngine {
    private var cachedContext: CIContext?
    private let contextLock = NSLock()

    /// 延迟创建 CIContext，避免 App 常驻时提前占用 GPU 相关内存。
    private var ciContext: CIContext {
        contextLock.lock()
        defer { contextLock.unlock() }
        if let cachedContext {
            return cachedContext
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        cachedContext = context
        return context
    }

    /// 扫描结束后释放图像处理上下文。
    func releaseResources() {
        contextLock.lock()
        cachedContext = nil
        contextLock.unlock()
    }

    /// 检测人脸矩形。
    func detect(in pixelBuffer: CVPixelBuffer) async throws -> [FaceObservation] {
        let request = DetectFaceRectanglesRequest()
        return try await request.perform(on: pixelBuffer, orientation: .up)
    }

    /// 生成对齐后的人脸特征向量。直接把 CIImage 交给 Vision，省掉两次 CGImage 渲染。
    func featureVector(for face: FaceObservation, in pixelBuffer: CVPixelBuffer) async throws -> [Float] {
        guard let cropped = makeFaceCIImage(face: face, pixelBuffer: pixelBuffer) else {
            throw FaceEngineError.cropFailed
        }
        let request = GenerateImageFeaturePrintRequest()
        let observation = try await request.perform(on: cropped)
        return try Self.floats(from: observation)
    }

    /// 生成预览图，用于录入/测试窗口。
    func previewImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(image, from: image.extent)
    }

    /// 人脸区域外扩、按 roll 旋转，再等比缩放并居中裁成 224×224 的 CIImage。
    private func makeFaceCIImage(face: FaceObservation, pixelBuffer: CVPixelBuffer) -> CIImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let box = face.boundingBox.cgRect

        var rect = CGRect(
            x: box.minX * extent.width,
            y: box.minY * extent.height,
            width: box.width * extent.width,
            height: box.height * extent.height
        )
        rect = rect.insetBy(dx: -rect.width * 0.28, dy: -rect.height * 0.32)
        rect = rect.intersection(extent)
        guard rect.width > 24, rect.height > 24 else { return nil }

        var cropped = image.cropped(to: rect)

        let radians = -face.roll.converted(to: .radians).value
        if abs(radians) > 0.02 {
            let center = CGPoint(x: cropped.extent.midX, y: cropped.extent.midY)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: CGFloat(radians))
                .translatedBy(x: -center.x, y: -center.y)
            cropped = cropped.transformed(by: transform)
        }

        let side: CGFloat = 224
        let width = cropped.extent.width
        let height = cropped.extent.height
        guard width > 1, height > 1 else { return nil }

        // 保持和旧版一致的「等比缩放 + 居中黑边」，避免已录入模板失效
        let scale = min(side / width, side / height)
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (side - scaled.extent.width) / 2 - scaled.extent.origin.x
        let offsetY = (side - scaled.extent.height) / 2 - scaled.extent.origin.y
        let positioned = scaled.transformed(
            by: CGAffineTransform(translationX: offsetX, y: offsetY)
        )
        let canvasRect = CGRect(x: 0, y: 0, width: side, height: side)
        let canvas = CIImage(color: CIColor.black).cropped(to: canvasRect)
        return positioned.composited(over: canvas).cropped(to: canvasRect)
    }

    /// 把 FeaturePrintObservation 转成 Float 数组。
    static func floats(from observation: FeaturePrintObservation) throws -> [Float] {
        switch observation.elementType {
        case .float:
            return observation.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
        case .double:
            return observation.data.withUnsafeBytes { raw in
                raw.bindMemory(to: Double.self).map { Float($0) }
            }
        @unknown default:
            throw FaceEngineError.unsupportedElementType
        }
    }

    /// 欧氏距离，值越小越相似。
    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return .greatestFiniteMagnitude
        }
        var sum: Double = 0
        for index in 0..<lhs.count {
            let delta = Double(lhs[index] - rhs[index])
            sum += delta * delta
        }
        return Float(sqrt(sum))
    }

    /// 对多个向量逐元素求平均。
    static func average(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var result = [Double](repeating: 0, count: first.count)
        var used = 0
        for vector in vectors where vector.count == first.count {
            for index in 0..<vector.count {
                result[index] += Double(vector[index])
            }
            used += 1
        }
        guard used > 0 else { return [] }
        return result.map { Float($0 / Double(used)) }
    }
}
