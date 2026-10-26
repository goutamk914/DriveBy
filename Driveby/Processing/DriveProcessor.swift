import AVFoundation
import Foundation

enum ProcessingOutcome {
    case processed(DriveAnalysis)
    case discarded(String)
    case failed(String)
}

enum DriveProcessor {
    static let clipPre = 6.0
    static let clipPost = 6.0

    static func process(folder: URL, sidecar: DriveSidecar, vehicle: VehicleParams, fetchSpeedLimits: Bool = true,
                        knownMap: OverpassClient.MapData? = nil) async -> ProcessingOutcome {
        let sensorURL = folder.appendingPathComponent(sidecar.sensorFile)
        guard let data = try? Data(contentsOf: sensorURL) else { return .failed("The sensor log is missing.") }
        let log = SensorLogParser.parse(data)
        guard !log.isEmpty else { return .discarded("No sensor data was recorded.") }

        let plan: DriveAnalyzer.Plan
        do {
            plan = try DriveAnalyzer.plan(log: log)
        } catch DriveAnalyzer.Failure.noGPS(let fixes) {
            return .failed("No usable GPS signal (\(fixes) good fixes).")
        } catch DriveAnalyzer.Failure.neverMoved {
            return .discarded("The car never started moving.")
        } catch DriveAnalyzer.Failure.tooShort(let d, let s) {
            return .discarded(String(format: "Trip too short to score (%.0f m, %.0f s). Needs 500 m and 2 min.", d, s))
        } catch {
            return .failed(error.localizedDescription)
        }

        let fetched = knownMap == nil && fetchSpeedLimits ? await OverpassClient.shared.mapData(for: plan.tiles) : nil
        let map = knownMap ?? fetched
        var analysis = DriveAnalyzer.analyze(plan: plan, log: log, vehicle: vehicle, ways: map?.ways, controls: map?.controls ?? [])

        if let videoName = sidecar.videoFile, let vStart = sidecar.videoStartT {
            let videoURL = folder.appendingPathComponent(videoName)
            if FileManager.default.fileExists(atPath: videoURL.path) {
                analysis.events = await ClipExporter.exportClips(video: videoURL, videoStartT: vStart, videoEndT: sidecar.videoEndT,
                                                                 events: analysis.events, folder: folder)
                if let highlights = analysis.highlights {
                    analysis.highlights = await ClipExporter.exportClips(video: videoURL, videoStartT: vStart, videoEndT: sidecar.videoEndT,
                                                                         moments: highlights, folder: folder)
                }
            }
        }
        return .processed(analysis)
    }
}

enum ClipExporter {
    static func clipCenter(_ e: DriveEvent) -> Double { e.kind == .idle ? e.tOffsetS + 3 : e.tPeakS }

    static func clipStartAsset(for e: DriveEvent, videoStartT: Double) -> Double {
        clipStartAsset(center: clipCenter(e), videoStartT: videoStartT)
    }

    static func clipCenter(_ m: DriveMoment) -> Double { (m.t + m.tEnd) / 2 }

    static func clipStartAsset(center: Double, videoStartT: Double) -> Double {
        max(center - DriveProcessor.clipPre - videoStartT, 0)
    }

    static func exportClips(video: URL, videoStartT: Double, videoEndT: Double?, moments: [DriveMoment], folder: URL) async -> [DriveMoment] {
        let asset = AVURLAsset(url: video)
        let durationSeconds: Double
        if let d = try? await asset.load(.duration), d.isNumeric { durationSeconds = CMTimeGetSeconds(d) }
        else if let end = videoEndT { durationSeconds = end - videoStartT }
        else { return moments }
        let clipsDir = folder.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        var out = moments
        for i in out.indices {
            let m = out[i]
            let center = clipCenter(m)
            let start = clipStartAsset(center: center, videoStartT: videoStartT)
            let end = min(center + DriveProcessor.clipPost - videoStartT, durationSeconds)
            guard end - start >= 2 else { out[i].clipPath = nil; continue }
            let name = "clips/\(m.kind.rawValue)_\(Int(m.t.rounded())).mov"
            let dst = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            if await export(asset: asset, from: start, to: end, dst: dst) { out[i].clipPath = name }
        }
        return out
    }

    static func exportClips(video: URL, videoStartT: Double, videoEndT: Double?, events: [DriveEvent], folder: URL) async -> [DriveEvent] {
        let asset = AVURLAsset(url: video)
        let durationSeconds: Double
        if let d = try? await asset.load(.duration), d.isNumeric { durationSeconds = CMTimeGetSeconds(d) }
        else if let end = videoEndT { durationSeconds = end - videoStartT }
        else { return events }
        guard durationSeconds > 1 else { return events }

        let clipsDir = folder.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        var out = events
        for i in out.indices {
            let e = out[i]
            let start = clipStartAsset(for: e, videoStartT: videoStartT)
            let end = min(clipCenter(e) + DriveProcessor.clipPost - videoStartT, durationSeconds)
            guard end - start >= 2 else { out[i].clipPath = nil; continue }
            let name = "clips/\(e.kind.rawValue)_\(Int(e.tOffsetS.rounded())).mov"
            let dst = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            if await export(asset: asset, from: start, to: end, dst: dst) { out[i].clipPath = name }
        }
        return out
    }

    private static func export(asset: AVAsset, from: Double, to: Double, dst: URL) async -> Bool {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        session.outputURL = dst
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                        end: CMTime(seconds: to, preferredTimescale: 600))
        return await withCheckedContinuation { cont in
            session.exportAsynchronously { cont.resume(returning: session.status == .completed) }
        }
    }
}
