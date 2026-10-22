import Foundation
import notify

/// Stops the music after a chosen time: fades it out, pauses, and turns the screen off.
final class SleepTimer: ObservableObject {
    static let choices = [15, 30, 45, 60, 90]

    @Published private(set) var endDate: Date?
    /// Ticks every 30 s so "23 dk" counts down on screen.
    @Published private(set) var now = Date()

    private var fire: DispatchWorkItem?
    private var tick: Timer?
    private let onFire: (@escaping () -> Void) -> Void

    /// `onFire` stops the music and calls its completion when done.
    init(onFire: @escaping (@escaping () -> Void) -> Void) {
        self.onFire = onFire
    }

    var remainingMinutes: Int? {
        endDate.map { max(1, Int(($0.timeIntervalSince(now) / 60).rounded(.up))) }
    }

    func start(minutes: Int) {
        cancel()
        endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        now = Date()
        let work = DispatchWorkItem { [weak self] in
            self?.onFire {
                // Asks the kiosk tweak to turn the screen off.
                notify_post("com.ibrahimkoc.ipod.lock")
            }
            self?.cancel()
        }
        fire = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes * 60), execute: work)
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.now = Date() }
    }

    func cancel() {
        fire?.cancel()
        tick?.invalidate()
        endDate = nil
    }
}
