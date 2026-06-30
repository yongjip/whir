import Foundation
import ServiceManagement

/// Start Whir automatically at login via SMAppService (macOS 13+). No helper
/// bundle or login-items entitlement needed — the main app registers itself.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Toggle and return the REAL resulting status. register() doesn't throw when
    /// the user disabled the item in System Settings — it returns
    /// `.requiresApproval`, so a bare Bool would falsely report success.
    @discardableResult
    static func set(_ on: Bool) -> SMAppService.Status {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Whir: launch-at-login set(\(on)) failed: \(error.localizedDescription)")
        }
        return SMAppService.mainApp.status
    }
}
