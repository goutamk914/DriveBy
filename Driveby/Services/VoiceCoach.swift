import AVFoundation
import OSLog

@MainActor
final class VoiceCoach: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "com.gkanakadandi.Driveby", category: "voice")
    private static let rateMultiplier: Float = 1.05

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String, interrupting: Bool = false) {
        if interrupting {
            synth.stopSpeaking(at: .immediate)
        } else if synth.isSpeaking {
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            log.error("Audio session for voice cue failed: \(error.localizedDescription, privacy: .public)")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.rateMultiplier
        utterance.prefersAssistiveTechnologySettings = true
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        releaseAudio()
    }

    private func releaseAudio() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error("Releasing audio session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.releaseAudio() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.releaseAudio() } }
    }
}
