import Foundation
import ServiceManagement

/// Launch-at-login via the modern SMAppService (macOS 13+, matches our floor).
enum LoginItem {

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// What macOS *reliably* knows about our login-item state, or `nil` when it
    /// cannot say. `.notFound` (app running from a location it can't register
    /// from, e.g. a build folder or a DMG) and `.requiresApproval` (registered,
    /// waiting on the user in System Settings) are both "unknown" — treating
    /// them as "off" would silently clobber the user's stored preference every
    /// time the Settings window opened.
    static var reportedState: Bool? {
        switch status {
        case .enabled:       return true
        case .notRegistered: return false
        default:             return nil
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("ClipVault: login item update failed: \(error.localizedDescription)")
            return false
        }
    }
}
