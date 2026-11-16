import AVFoundation
import Foundation

/// Says "Myślę." through AVSpeechSynthesizer when a call is still running after
/// `delay`, then waits for the phrase to finish before handing the answer to
/// Siri, so the two voices do not overlap.
///
/// Experimental (spike STR-1281): Siri owns the audio route during an intent;
/// whether our utterance is heard on AirPods from the lock screen is what the
/// device test decides. Failures are silent — the answer still comes back.
final class SpeechThinkingCue: NSObject, ThinkingCue, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    private let delay: Duration
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance being waited for; callbacks and the safety timer only
    /// finish their own utterance, never a later one.
    private var waiting: (utterance: AVSpeechUtterance, cont: CheckedContinuation<Void, Never>)?
    private let lock = NSLock()

    init(delay: Duration = .milliseconds(1500)) {
        self.delay = delay
        super.init()
        synthesizer.delegate = self
    }

    func around(_ operation: @Sendable () async -> HandsfreeOutcome) async -> HandsfreeOutcome {
        let cue = Task { [delay] in
            try await Task.sleep(for: delay)
            await self.speak(VoicePhrases.thinking)
        }
        let outcome = await operation()
        cue.cancel()
        _ = await cue.result  // if "Myślę" already started, let it finish
        return outcome
    }

    private func speak(_ text: String) async {
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playback, mode: .voicePrompt,
                                  options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try audio.setActive(true)
        } catch {
            return
        }
        defer { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "pl-PL")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock { waiting = (utterance, cont) }
            synthesizer.speak(utterance)
            // Never hang the intent if the synthesizer gets no audio route.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.resume(utterance) }
        }
    }

    private func resume(_ utterance: AVSpeechUtterance) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let waiting, waiting.utterance === utterance else { return nil }
            self.waiting = nil
            return waiting.cont
        }
        cont?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume(utterance)
    }
}
