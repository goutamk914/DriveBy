//  VoiceCoach.swift — Driveby
//  Speaks the live coach's cues out loud, so the driver never has to look at the phone.
//  Uses the navigation-prompt audio mode: music and podcasts duck (not stop) while Driveby talks,
//  then come back. Keeps speaking with the screen locked (UIBackgroundModes: audio — used only for
//  these prompts). Nothing is recorded: the dashcam captures no audio.

import AVFoundation
import OSLog

@MainActor
final class VoiceCoach: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "com.gkanakadandi.Driveby", category: "voice")
    /// A touch quicker than default: cues should be over before the next thing happens on the road.
    private static let rateMultiplier: Float = 1.05

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speaks `text`. Normally skipped if something is already being said (cues never pile up);
    /// `interrupting` cuts the current cue off instead (for messages that must be heard).
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
            // Still try to speak: the default session plays too, it just won't duck other audio.
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

    // MARK: AVSpeechSynthesizerDelegate — give the music back as soon as we're done talking.

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.releaseAudio() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.releaseAudio() } }
    }
}
