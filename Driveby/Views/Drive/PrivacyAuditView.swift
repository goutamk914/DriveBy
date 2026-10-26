import AVFoundation
import SwiftUI

struct PrivacyAuditView: View {
    let record: DriveRecord
    @Environment(DriveStore.self) private var drives
    @State private var frames: [(time: Double, image: UIImage)] = []
    @State private var flagged: Set<Int> = []
    @State private var loading = true
    @State private var enlarged: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Tap any frame with a readable face or plate.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if loading {
                    ProgressView("Sampling frames…").frame(maxWidth: .infinity).padding(.top, 40)
                } else if frames.isEmpty {
                    ContentUnavailableView { Text("No video") } description: { Text("Deleted or never recorded.") }
                } else {
                    Card {
                        let n = frames.count
                        Text("\(flagged.count) of \(n) frames flagged").font(.headline)
                        Text(flagged.isEmpty
                             ? "No leaks found in this sample."
                             : String(format: "Leak rate %.0f%% on this sample.",
                                      Double(flagged.count) / Double(n) * 100))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(frames.indices, id: \.self) { i in
                            Image(uiImage: frames[i].image)
                                .resizable().aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .overlay(alignment: .topLeading) {
                                    Text(Fmt.clock(frames[i].time)).font(.caption2.monospacedDigit()).padding(3)
                                        .background(.black.opacity(0.5)).foregroundStyle(.white)
                                }
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(flagged.contains(i) ? Color.red : Color.clear, lineWidth: 3))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture {
                                    if flagged.contains(i) { flagged.remove(i) } else { flagged.insert(i) }
                                }
                                .onLongPressGesture { enlarged = i }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Privacy spot-check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Resample") { Task { await load() } }.disabled(loading)
            }
        }
        .sheet(item: Binding(get: { enlarged.map(IdentifiedIndex.init) }, set: { enlarged = $0?.id })) { item in
            if frames.indices.contains(item.id) {
                Image(uiImage: frames[item.id].image).resizable().scaledToFit().padding().presentationDetents([.medium, .large])
            }
        }
        .task { await load() }
    }

    private struct IdentifiedIndex: Identifiable { var id: Int }

    private func load() async {
        loading = true
        flagged = []
        defer { loading = false }
        guard let url = drives.videoURL(record) else { frames = []; return }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { frames = []; return }
        let total = CMTimeGetSeconds(duration)
        let times = (0..<20).map { _ in Double.random(in: 0..<max(total, 0.1)) }.sorted()
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 540)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var out: [(Double, UIImage)] = []
        for t in times {
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                out.append((t, UIImage(cgImage: cg)))
            }
        }
        frames = out.map { (time: $0.0, image: $0.1) }
    }
}
