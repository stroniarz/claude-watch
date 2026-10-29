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
    private var finished: CheckedContinuation<Void, Never>?
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
            lock.withLock { finished = cont }
            synthesizer.speak(utterance)
            // Never hang the intent if the synthesizer gets no audio route.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.resume() }
        }
    }

    private func resume() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { finished = nil }
            return finished
        }
        cont?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume()
    }
}
