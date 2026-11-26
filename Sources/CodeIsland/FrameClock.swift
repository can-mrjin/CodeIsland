import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Redraws `content` on a shared display-synchronized clock (`FrameTicker`),
/// adapting automatically to the host screen's native refresh rate (up to
/// 120 Hz on ProMotion displays, 60 Hz on standard displays).
///
/// Every clock shares one `CADisplayLink` (with a headless timer fallback for
/// unit tests without a bound `NSScreen`), so all moving mascots and shimmers
/// advance in lockstep on VSync without redundant wakeups. When no clock is on
/// screen, the display link is invalidated immediately for zero idle CPU.
struct FrameClock<Content: View>: View {
    let interval: TimeInterval
    let content: (TimeInterval) -> Content

    init(interval: TimeInterval, @ViewBuilder content: @escaping (TimeInterval) -> Content) {
        self.interval = FrameTicker.quantizedInterval(for: interval)
        self.content = content
    }

    var body: some View {
        FrameClockFace(beat: FrameTicker.shared.beat(every: interval), content: content)
    }
}

private struct FrameClockFace<Content: View>: View {
    let beat: FrameBeat
    let content: (TimeInterval) -> Content

    var body: some View {
        content(beat.now)
            // The ticker runs while some clock is on screen, and stops with the
            // last one: a still island schedules nothing.
            .task {
                beat.attach()
                defer { beat.detach() }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
    }
}

/// The time of the latest tick, for the clocks of one interval.
@MainActor
@Observable
final class FrameBeat {
    let interval: TimeInterval
    fileprivate(set) var now = Date.timeIntervalSinceReferenceDate
    @ObservationIgnored fileprivate var clocks = 0
    @ObservationIgnored fileprivate var lastTick: TimeInterval = 0

    fileprivate init(interval: TimeInterval) {
        self.interval = interval
    }

    fileprivate func attach() {
        clocks += 1
        FrameTicker.shared.start()
    }

    fileprivate func detach() {
        clocks = max(0, clocks - 1)
        FrameTicker.shared.stopIfIdle()
    }
}

private final class DisplayLinkProxy: NSObject {
    var onTick: (() -> Void)?

    @objc func handleTick(_ sender: CADisplayLink) {
        onTick?()
    }
}

/// The single VSync-aligned clock behind every `FrameClock`.
/// Adapts to the bound `NSScreen.maximumFramesPerSecond` (60–120 Hz) via
/// `CADisplayLink`, and stops completely once no clock is attached.
@MainActor
final class FrameTicker {
    static let shared = FrameTicker()

    /// High-refresh continuous motion step (120 Hz native grid).
    /// Callers passing `<= 0.05` (the legacy 20 fps grid) are promoted to
    /// native VSync smooth motion so mascots and shimmers run at full display
    /// refresh rate on ProMotion (120 Hz) and standard (60 Hz) screens.
    nonisolated static let step: TimeInterval = 1.0 / 120.0
    nonisolated static let smoothPromotionThreshold: TimeInterval = 0.05

    private var beats: [Int: FrameBeat] = [:]
    private weak var boundScreen: NSScreen?
    private(set) var targetRefreshRate: Int = 60
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var fallbackTask: Task<Void, Never>?

    nonisolated static func clampedRefreshRate(_ rawFPS: Int) -> Int {
        guard rawFPS > 0 else { return 60 }
        return min(120, max(60, rawFPS))
    }

    nonisolated static func quantizedInterval(for interval: TimeInterval) -> TimeInterval {
        if interval <= smoothPromotionThreshold + 1e-9 {
            return step
        }
        return max(step, (interval / 0.05).rounded() * 0.05)
    }

    nonisolated static func steps(for interval: TimeInterval) -> Double {
        max(1, (quantizedInterval(for: interval) / step).rounded())
    }

    /// Whether the ticker is running; it stops once no clock is attached.
    var isRunning: Bool { displayLink != nil || fallbackTask != nil }

    /// Bind the ticker to the screen currently hosting the notch panel so
    /// `CADisplayLink` tracks ProMotion (120 Hz) vs external (60 Hz) displays.
    func bind(to screen: NSScreen?) {
        let newFPS = Self.clampedRefreshRate(screen?.maximumFramesPerSecond ?? 60)
        let screenChanged = boundScreen !== screen || targetRefreshRate != newFPS
        boundScreen = screen
        targetRefreshRate = newFPS

        if screenChanged, isRunning {
            stopDrivers()
            start()
        }
    }

    func beat(every interval: TimeInterval) -> FrameBeat {
        let quantized = Self.quantizedInterval(for: interval)
        let key = Int((quantized * 1000).rounded())
        if let beat = beats[key] { return beat }
        let beat = FrameBeat(interval: quantized)
        beats[key] = beat
        return beat
    }

    fileprivate func start() {
        guard !isRunning else { return }
        guard hasActiveClocks else { return }

        if let screen = boundScreen {
            let proxy = DisplayLinkProxy()
            proxy.onTick = { [weak self] in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            let link = screen.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.handleTick(_:)))
            let maxFPS = Float(targetRefreshRate)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(60, maxFPS),
                maximum: maxFPS,
                preferred: maxFPS
            )
            link.add(to: .main, forMode: .common)
            self.displayLinkProxy = proxy
            self.displayLink = link
            return
        }

        // Headless fallback (e.g. unit tests without an attached NSScreen).
        let frameInterval = 1.0 / Double(targetRefreshRate)
        fallbackTask = Task { [weak self] in
            while let self, self.hasActiveClocks, !Task.isCancelled {
                let wait = frameInterval - Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: frameInterval)
                try? await Task.sleep(for: .seconds(max(0.001, wait)))
                guard !Task.isCancelled else { break }
                self.tick()
            }
            self?.fallbackTask = nil
        }
    }

    fileprivate func stopIfIdle() {
        guard !hasActiveClocks else { return }
        stopDrivers()
    }

    private var hasActiveClocks: Bool {
        beats.values.contains(where: { $0.clocks > 0 })
    }

    private func stopDrivers() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    private func tick() {
        guard hasActiveClocks else {
            stopDrivers()
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        let nativeStep = 1.0 / Double(targetRefreshRate)
        for beat in beats.values where beat.clocks > 0 {
            if beat.interval <= Self.step + 1e-9 {
                beat.lastTick = now
                beat.now = now
            } else if now - beat.lastTick >= beat.interval - nativeStep * 0.25 {
                beat.lastTick = now
                beat.now = now
            }
        }
    }
}
