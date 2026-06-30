import Foundation
import SwiftUI
import WhirCore

/// Live CPU / RAM / disk, refreshed on a timer while the popover is open.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    private let sampler = SystemSampler()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        _ = sampler.cpu()                 // prime the CPU delta
        snapshot = sampler.sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.snapshot = self.sampler.sample() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}
