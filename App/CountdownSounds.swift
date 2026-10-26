import AVFoundation
import Foundation

/// Alerts before tracking starts, in the sounds of the WWV time signal on 2.5, 5, 10, 15 and
/// 20 MHz: a minute out, its 0.8 s hour tone at 1500 Hz; over the last ten seconds, a 5 ms tick
/// of 1000 Hz (five whole cycles) each second, then the 0.8 s minute tone at 1000 Hz as tracking
/// begins.
///
/// The sounds are scheduled on the audio clock, so each tick lands on its second however busy
/// the tracking loop is.
@MainActor
final class CountdownSounds {
    static let seconds = 10
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private lazy var tick = Self.tone(frequency: 1000, duration: 0.005, format: format)
    private lazy var mark = Self.tone(frequency: 1000, duration: 0.8, format: format, fade: 0.005)
    private lazy var warning = Self.tone(frequency: 1500, duration: 0.8, format: format, fade: 0.005)
    /// The moment the alerts are scheduled up to, and which ones.
    private var armedFor: Date?
    private var armedWith: (warning: Bool, countdown: Bool)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Alerts for a start at `start`: a warning a minute out and the ten-second countdown, as
    /// chosen. Called again and again while waiting: it only reschedules when the start time
    /// moves, and does nothing until the first alert is close.
    func alert(before start: Date, minuteWarning: Bool, countdown: Bool) {
        let remaining = start.timeIntervalSinceNow
        let lead = minuteWarning && remaining > 60 ? 61.0 : Double(Self.seconds) + 1
        guard remaining > 0, remaining <= lead, minuteWarning || countdown else { return }
        if let armedFor, let armedWith, abs(armedFor.timeIntervalSince(start)) < 0.05,
           armedWith == (minuteWarning, countdown) { return }
        guard startEngine() else { return }
        player.stop()
        if minuteWarning, remaining > 60 { schedule(warning, at: start - 60) }
        if countdown {
            for k in stride(from: Self.seconds, through: 1, by: -1) {
                let when = start - Double(k)
                if when.timeIntervalSinceNow > 0.02 { schedule(tick, at: when) }
            }
            schedule(mark, at: start)
        }
        player.play()
        armedFor = start
        armedWith = (minuteWarning, countdown)
    }

    /// Silences a countdown in progress (tracking stopped, or the start no longer applies).
    func cancel() {
        guard armedFor != nil else { return }
        armedFor = nil
        armedWith = nil
        player.stop()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, at date: Date) {
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: max(0, date.timeIntervalSinceNow))
        player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: host))
    }

    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        #if os(iOS)
        // Heard with the silent switch on, and over whatever else is playing.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// A sine burst starting at zero phase. Five cycles of 1000 Hz end at zero too, so the tick
    /// needs no fade; the long tone gets a short one at each end.
    static func tone(frequency: Double, duration: Double, format: AVAudioFormat, fade: Double = 0) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let count = AVAudioFrameCount(duration * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let samples = buffer.floatChannelData![0]
        let fadeCount = fade * rate
        for i in 0..<Int(count) {
            var gain = 0.6
            if fadeCount > 0 { gain *= min(1, Double(i) / fadeCount, Double(Int(count) - i) / fadeCount) }
            samples[i] = Float(gain * sin(2 * .pi * frequency * Double(i) / rate))
        }
        return buffer
    }
}
