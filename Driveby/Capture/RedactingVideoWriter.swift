import AVFoundation
import CoreImage
import Foundation

final class RedactingVideoWriter {
    let url: URL
    private let redactor: Redactor
    private let ciContext: CIContext
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var failed = false
    private var finishing = false
    private(set) var firstT: Double?
    private(set) var lastT: Double?
    private(set) var framesWritten = 0
    private(set) var framesDropped = 0
    private(set) var dimensions: (width: Int, height: Int)?

    init(url: URL, redactor: Redactor) {
        self.url = url
        self.redactor = redactor
        ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }

    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer, t: Double) -> Redactor.Result? {
        guard !failed, !finishing, let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard setUp(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src), start: pts) else { return nil }
            firstT = t
        }
        guard let writer, let input, let adaptor, writer.status == .writing else {
            failed = true
            return nil
        }

        let result = redactor.process(src, t: t)

        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            framesDropped += 1
            return result
        }
        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer) == kCVReturnSuccess,
              let out = outBuffer else {
            framesDropped += 1
            return result
        }

        let image = Redactor.redactedImage(src, rects: result.blurRects)
        ciContext.render(image, to: out)

        if adaptor.append(out, withPresentationTime: pts) {
            framesWritten += 1
            lastT = t
        } else {
            framesDropped += 1
            if writer.status == .failed { failed = true }
        }
        return result
    }

    private func setUp(width: Int, height: Int, start: CMTime) -> Bool {
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            w.shouldOptimizeForNetworkUse = false
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 3_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
            guard w.canAdd(i) else { failed = true; return false }
            w.add(i)
            guard w.startWriting() else { failed = true; return false }
            w.startSession(atSourceTime: start)
            writer = w; input = i; adaptor = a
            dimensions = (width, height)
            return true
        } catch {
            failed = true
            return false
        }
    }

    var isWriting: Bool { writer?.status == .writing }

    func finish(_ completion: @escaping (_ ok: Bool) -> Void) {
        guard !finishing, let writer, let input, writer.status == .writing else { completion(false); return }
        finishing = true
        input.markAsFinished()
        writer.finishWriting { completion(writer.status == .completed) }
    }

    func cancel() {
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
