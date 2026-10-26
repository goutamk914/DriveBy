import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

final class Redactor {
    struct LeadVehicle {
        var rectTopLeft: CGRect
        var widthPx: Double
    }

    struct Result {
        var blurRects: [CGRect] = []
        var lead: LeadVehicle? = nil
        var analyzed = false
        var faceCount = 0
        var vehicleCount = 0
        var plateCount = 0
    }

    struct Capabilities { var objects: Bool; var plates: Bool }

    private var objectRequest: VNCoreMLRequest?
    private var plateRequest: VNCoreMLRequest?
    private var prepared = false
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let textRequest: VNDetectTextRectanglesRequest = {
        let r = VNDetectTextRectanglesRequest()
        r.reportCharacterBoxes = false
        return r
    }()
    private let humanRequest = VNDetectHumanRectanglesRequest()

    var minInterval: Double = 1.0 / 15.0
    private var lastAnalysisT = -Double.infinity
    private var recent: [(t: Double, rects: [CGRect])] = []
    private let persistFor = 0.5
    private(set) var lastResult = Result()

    private(set) var capabilities = Capabilities(objects: false, plates: false)

    static let vehicleLabels: Set<String> = ["car", "bus", "truck", "motorcycle"]
    static let leadLabels: Set<String> = ["car", "bus", "truck"]

    init() {}

    func prepare() {
        guard !prepared else { return }
        objectRequest = Self.request(model: "yolov8n")
        plateRequest = Self.request(model: "plate_detector")
        capabilities = Capabilities(objects: objectRequest != nil, plates: plateRequest != nil)
        prepared = true
    }

    private static func request(model name: String) -> VNCoreMLRequest? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let ml = try? MLModel(contentsOf: url, configuration: config),
              let vn = try? VNCoreMLModel(for: ml) else { return nil }
        let r = VNCoreMLRequest(model: vn)
        r.imageCropAndScaleOption = .scaleFit
        return r
    }

    func process(_ pb: CVPixelBuffer, t: Double) -> Result {
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        recent.removeAll { t - $0.t > persistFor }

        guard t - lastAnalysisT >= minInterval else {
            var r = Result()
            r.blurRects = recent.flatMap(\.rects).map { toPixels(expand($0, by: 0.2), w: w, h: h) }
            r.faceCount = lastResult.faceCount; r.vehicleCount = lastResult.vehicleCount; r.plateCount = lastResult.plateCount
            return r
        }
        lastAnalysisT = t

        var requests: [VNRequest] = [faceRequest]
        if let o = objectRequest { requests.append(o) } else { requests.append(humanRequest) }
        if let p = plateRequest { requests.append(p) } else { requests.append(textRequest) }
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try handler.perform(requests) } catch {
            lastAnalysisT = -Double.infinity
            var r = Result()
            r.blurRects = recent.flatMap(\.rects).map { toPixels(expand($0, by: 0.3), w: w, h: h) }
            return r
        }

        var rects: [CGRect] = []
        var result = Result(analyzed: true)

        for face in faceRequest.results ?? [] {
            rects.append(expand(face.boundingBox, by: 0.3))
            result.faceCount += 1
        }

        var bestLead: (CGRect, Double)? = nil
        let objects = (objectRequest?.results as? [VNRecognizedObjectObservation]) ?? []
        for obj in objects {
            guard let top = obj.labels.first, top.confidence >= 0.3 else { continue }
            let b = obj.boundingBox
            if Self.vehicleLabels.contains(top.identifier) {
                if Thresholds.isOwnHood(minY: Double(b.minY), width: Double(b.width)) { continue }
                result.vehicleCount += 1
                rects.append(CGRect(x: b.minX + 0.15 * b.width, y: b.minY, width: 0.7 * b.width, height: 0.55 * b.height))
                if Self.leadLabels.contains(top.identifier), top.confidence >= 0.35, abs(Double(b.midX) - 0.5) <= 0.15 {
                    let widthPx = Double(b.width) * w
                    if bestLead == nil || widthPx > bestLead!.1 { bestLead = (b, widthPx) }
                }
            } else if top.identifier == "person" {
                rects.append(CGRect(x: b.minX, y: b.minY + 0.7 * b.height, width: b.width, height: 0.3 * b.height))
            }
        }
        if objectRequest == nil {
            for human in humanRequest.results ?? [] {
                let b = human.boundingBox
                rects.append(CGRect(x: b.minX, y: b.minY + 0.7 * b.height, width: b.width, height: 0.3 * b.height))
            }
        }

        if let plateRequest {
            for p in (plateRequest.results as? [VNRecognizedObjectObservation]) ?? [] where (p.labels.first?.confidence ?? 0) >= 0.2 {
                rects.append(expand(p.boundingBox, by: 0.25))
                result.plateCount += 1
            }
        } else {
            for text in textRequest.results ?? [] {
                let b = text.boundingBox
                let aspect = (Double(b.width) * w) / max(Double(b.height) * h, 1)
                if aspect > 1.2, aspect < 6.5, b.height < 0.12, b.maxY < 0.75 {
                    rects.append(expand(b, by: 0.35))
                    result.plateCount += 1
                }
            }
        }

        if let best = bestLead {
            let b = best.0
            result.lead = LeadVehicle(rectTopLeft: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), widthPx: best.1)
        }

        let carried = recent.flatMap(\.rects).map { expand($0, by: 0.15) }
        recent.append((t, rects))
        result.blurRects = (rects + carried).map { toPixels($0, w: w, h: h) }
        lastResult = result
        return result
    }

    func reset() {
        recent.removeAll()
        lastAnalysisT = -Double.infinity
        lastResult = Result()
    }

    private func expand(_ r: CGRect, by frac: CGFloat) -> CGRect {
        let dx = max(r.width * frac / 2, 0.004), dy = max(r.height * frac / 2, 0.006)
        return r.insetBy(dx: -dx, dy: -dy)
    }

    private func toPixels(_ r: CGRect, w: Double, h: Double) -> CGRect {
        let pad = 6.0
        let x = Double(r.minX) * w - pad, y = Double(r.minY) * h - pad
        let width = Double(r.width) * w + 2 * pad, height = Double(r.height) * h + 2 * pad
        return CGRect(x: x, y: y, width: width, height: height).intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    static func redactedImage(_ pb: CVPixelBuffer, rects: [CGRect]) -> CIImage {
        let base = CIImage(cvPixelBuffer: pb)
        let clamped = base.clampedToExtent()
        var out = base
        for raw in rects {
            let rect = raw.intersection(base.extent).integral
            guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { continue }
            let side = max(rect.width, rect.height)
            let pixellated = clamped.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: Double(max(side / 6, 8)),
                kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY),
            ])
            let patch = pixellated.clampedToExtent().applyingGaussianBlur(sigma: Double(max(side / 8, 6))).cropped(to: rect)
            out = patch.composited(over: out)
        }
        return out.cropped(to: base.extent)
    }
}
