//  Redactor.swift — Driveby
//  Phase 4.1 / 5.2 on-device: finds every face and licence plate to blur, and the lead
//  vehicle in our lane for following distance — in ONE Vision pass per analysed frame.
//
//  Detectors (all on-device, nothing leaves the phone):
//   • Faces            Apple Vision VNDetectFaceRectanglesRequest
//   • Vehicles/people  YOLOv8n (COCO) Core ML model bundled as MLModels/yolov8n.mlpackage
//   • Plates           MLModels/plate_detector.mlpackage if you add one; otherwise we ERR TOWARD
//                      OVER-BLURRING: the plate zone of every detected vehicle is blurred, plus every
//                      plate-shaped text region Vision finds.
//   • Pedestrian heads the top 30% of every person box (faces too small for the face detector).
//  Boxes are padded and persist briefly across frames so a one-frame detector miss doesn't leak.

import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

final class Redactor {
    struct LeadVehicle {
        var rectTopLeft: CGRect     // normalised, origin top-left (data-contract `lead` box)
        var widthPx: Double
    }

    struct Result {
        var blurRects: [CGRect] = []    // PIXEL coordinates, origin bottom-left (Core Image space)
        var lead: LeadVehicle? = nil
        var analyzed = false            // fresh detection on this frame (vs. persisted boxes)
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

    /// Minimum seconds between fresh analyses (1 / detection Hz). Between analyses, the last boxes are reused.
    var minInterval: Double = 1.0 / 15.0
    private var lastAnalysisT = -Double.infinity
    private var recent: [(t: Double, rects: [CGRect])] = []   // normalised, bottom-left
    private let persistFor = 0.5
    private(set) var lastResult = Result()

    private(set) var capabilities = Capabilities(objects: false, plates: false)

    static let vehicleLabels: Set<String> = ["car", "bus", "truck", "motorcycle"]
    static let leadLabels: Set<String> = ["car", "bus", "truck"]

    init() {}

    /// Loads the Core ML models (the first load compiles for the Neural Engine and can take seconds,
    /// so this runs on the camera's session queue, never the main thread). Idempotent.
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
        r.imageCropAndScaleOption = .scaleFit   // YOLO is trained letterboxed
        return r
    }

    /// Analyse (or reuse) detections for this frame. Must be called on ONE serial queue.
    func process(_ pb: CVPixelBuffer, t: Double) -> Result {
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        recent.removeAll { t - $0.t > persistFor }

        guard t - lastAnalysisT >= minInterval else {
            // Reuse: union of recent boxes, expanded 20% to cover motion since they were found.
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
            // Detection failed: blur with whatever we had (never write an un-analysed frame bare
            // if we have recent boxes), and try again next frame.
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
                result.vehicleCount += 1
                // Plate zone: central 70% width, bottom 55% of the vehicle (front or rear plate).
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
                // plate-like: wider than tall, small, and in the lower 75% of the frame
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

        // Over-blur: this frame's boxes PLUS the previous analyses' (covers a one-frame miss).
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

    // MARK: geometry

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

    // MARK: blur

    /// The blur itself: pixellate, then Gaussian — irreversible, and hard enough that a plate
    /// can't be read back. Coordinates in Core Image space (origin bottom-left).
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
