import Foundation
import AppKit

/// Subtle confirmation cue after copy-back / Quick Paste actions.
/// Sound was removed by user preference; a light haptic tick remains.
@MainActor
final class FeedbackController {

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func playCopiedAffirmation() {
        if settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
