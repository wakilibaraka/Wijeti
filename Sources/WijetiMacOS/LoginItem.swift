import Foundation
import ServiceManagement

/// "Launch at login", in exactly one place.
///
/// Onboarding and Preferences both offer this, and the two must not drift apart: a toggle that
/// reports one thing while `SMAppService` holds another is worse than having no toggle at all.
/// It also keeps the `try` and the "needs approval" branch in one spot.
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item and returns the state that actually resulted.
    ///
    /// macOS can park the request in System Settings waiting for approval. When it does, open
    /// that pane rather than leaving the user with a switch that silently springs back.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval {
                    // Not a throwing call, unlike register/unregister — hence no `try`.
                    SMAppService.openSystemSettingsLoginItems()
                } else {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("login item error: %@", error.localizedDescription)
        }
        return isEnabled
    }
}
