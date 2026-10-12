//  LogScanner.swift — Driveby
//  Reads the text on a photo or scan of a paper driving log with Apple Vision — entirely on the
//  phone; the image is never saved or uploaded. Turning that text into hours is Core/PaperLog.swift.

import SwiftUI
import Vision
import VisionKit

enum LogScanner {
    enum Failure: LocalizedError {
        case unreadableImage
        var errorDescription: String? { "That image couldn't be opened. Try another photo." }
    }

    /// Recognised rows of text from every page, top to bottom.
    static func lines(from images: [UIImage]) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            try images.flatMap { try lines(in: $0) }
        }.value
    }

    private static func lines(in image: UIImage) throws -> [String] {
        guard let cg = image.cgImage else { throw Failure.unreadableImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false          // dates, times and initials — not prose
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation)).perform([request])
        let fragments = (request.results ?? []).compactMap { observation -> OCRFragment? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox           // normalised, origin bottom-left
            return OCRFragment(text: text, minX: box.minX, midY: 1 - box.midY, height: box.height)
        }
        return PaperLog.rows(fragments)
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// The system document camera (edge detection, perspective correction, multiple pages).
struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onScan((0..<scan.pageCount).map(scan.imageOfPage(at:)))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError(error)
        }
    }
}
