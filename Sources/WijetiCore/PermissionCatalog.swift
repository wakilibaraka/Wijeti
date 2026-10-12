import Foundation

/// One thing macOS may ask the user to allow, described as pure data.
///
/// Widgets are arbitrary scripts, so the set of permissions they can need is open-ended. Keeping
/// the *description* here (AppKit-free) and the *probing* in the macOS layer means adding a
/// permission is one entry in `PermissionCatalog.all`, and tests can check the entries against
/// `Info.plist` and the entitlements file without importing any platform framework.
public struct PermissionSpec: Identifiable, Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case essentials = "Essentials"
        case privacy = "Privacy"
        case system = "System access"
        case automation = "Automation"
    }

    public let id: String
    public let title: String
    public let reason: String
    public let group: Group
    /// `x-apple.systempreferences:` anchor of the pane that grants it.
    public let anchor: String?
    /// `Info.plist` keys macOS requires before it will show the prompt at all.
    public let usageKeys: [String]
    /// Entitlements the hardened runtime requires for this access.
    public let entitlements: [String]
    /// Bundle id of the app being scripted, for Automation targets.
    public let automationTarget: String?

    public init(
        id: String,
        title: String,
        reason: String,
        group: Group,
        anchor: String?,
        usageKeys: [String] = [],
        entitlements: [String] = [],
        automationTarget: String? = nil
    ) {
        self.id = id
        self.title = title
        self.reason = reason
        self.group = group
        self.anchor = anchor
        self.usageKeys = usageKeys
        self.entitlements = entitlements
        self.automationTarget = automationTarget
    }

    /// Search text for the permissions list.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle) || reason.lowercased().contains(needle)
    }
}

public enum PermissionCatalog {
    private static let security = "com.apple.preference.security?"

    /// Common apps a widget scripts with AppleScript. Each gets its own Automation row, because
    /// macOS grants Automation per target app and only lists Wijeti once one has been asked.
    public static let automationTargets: [(name: String, bundleID: String, reason: String)] = [
        ("Music", "com.apple.Music", "Now-playing and playback widgets for Apple Music."),
        ("Spotify", "com.spotify.client", "Now-playing and lyrics widgets for Spotify."),
        ("System Events", "com.apple.systemevents", "Widgets that read frontmost app, window or UI state."),
        ("Finder", "com.apple.finder", "Widgets that list or open files and folders."),
        ("Safari", "com.apple.Safari", "Widgets that read the current tab or reading list."),
        ("Calendar", "com.apple.iCal", "Calendar widgets that script the Calendar app."),
        ("Reminders", "com.apple.reminders", "To-do widgets that script Reminders."),
        ("Mail", "com.apple.mail", "Widgets that count or list unread mail."),
    ]

    public static let all: [PermissionSpec] = essentials + privacy + system + automation

    public static func spec(id: String) -> PermissionSpec? {
        all.first { $0.id == id }
    }

    public static func specs(in group: PermissionSpec.Group) -> [PermissionSpec] {
        all.filter { $0.group == group }
    }

    // MARK: - Entries

    private static let essentials: [PermissionSpec] = [
        PermissionSpec(
            id: "location", title: "Location",
            reason: "Weather widgets and anything that reports where you are.",
            group: .essentials, anchor: security + "Privacy_LocationServices",
            usageKeys: ["NSLocationWhenInUseUsageDescription"],
            entitlements: ["com.apple.security.personal-information.location"]
        ),
        PermissionSpec(
            id: "notifications", title: "Notifications",
            reason: "Background refreshes and alerts from widgets.",
            group: .essentials, anchor: "com.apple.preference.notifications"
        ),
        PermissionSpec(
            id: "accessibility", title: "Accessibility",
            reason: "Widgets that read window titles or react to keyboard and app focus.",
            group: .essentials, anchor: security + "Privacy_Accessibility"
        ),
    ]

    private static let privacy: [PermissionSpec] = [
        PermissionSpec(
            id: "calendars", title: "Calendars",
            reason: "Agenda and calendar widgets that read your events.",
            group: .privacy, anchor: security + "Privacy_Calendars",
            usageKeys: ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"],
            entitlements: ["com.apple.security.personal-information.calendars"]
        ),
        PermissionSpec(
            id: "reminders", title: "Reminders",
            reason: "To-do widgets that read your reminders.",
            group: .privacy, anchor: security + "Privacy_Reminders",
            usageKeys: ["NSRemindersFullAccessUsageDescription", "NSRemindersUsageDescription"],
            entitlements: ["com.apple.security.personal-information.calendars"]
        ),
        PermissionSpec(
            id: "contacts", title: "Contacts",
            reason: "Birthday and people widgets.",
            group: .privacy, anchor: security + "Privacy_Contacts",
            usageKeys: ["NSContactsUsageDescription"],
            entitlements: ["com.apple.security.personal-information.addressbook"]
        ),
        PermissionSpec(
            id: "photos", title: "Photos",
            reason: "Photo-frame widgets that show pictures from your library.",
            group: .privacy, anchor: security + "Privacy_Photos",
            usageKeys: ["NSPhotoLibraryUsageDescription"],
            entitlements: ["com.apple.security.personal-information.photos-library"]
        ),
        PermissionSpec(
            id: "camera", title: "Camera",
            reason: "Widgets that show or use the camera.",
            group: .privacy, anchor: security + "Privacy_Camera",
            usageKeys: ["NSCameraUsageDescription"],
            entitlements: ["com.apple.security.device.camera"]
        ),
        PermissionSpec(
            id: "microphone", title: "Microphone",
            reason: "Audio-level and voice widgets.",
            group: .privacy, anchor: security + "Privacy_Microphone",
            usageKeys: ["NSMicrophoneUsageDescription"],
            entitlements: ["com.apple.security.device.audio-input"]
        ),
        PermissionSpec(
            id: "bluetooth", title: "Bluetooth",
            reason: "Widgets that show headphone, mouse or keyboard battery levels.",
            group: .privacy, anchor: security + "Privacy_Bluetooth",
            usageKeys: ["NSBluetoothAlwaysUsageDescription"],
            entitlements: ["com.apple.security.device.bluetooth"]
        ),
        PermissionSpec(
            id: "media", title: "Media & Apple Music",
            reason: "Widgets that read your music library.",
            group: .privacy, anchor: security + "Privacy_Media",
            usageKeys: ["NSAppleMusicUsageDescription"]
        ),
        PermissionSpec(
            id: "speech", title: "Speech Recognition",
            reason: "Widgets that transcribe or react to speech.",
            group: .privacy, anchor: security + "Privacy_SpeechRecognition",
            usageKeys: ["NSSpeechRecognitionUsageDescription"]
        ),
        PermissionSpec(
            id: "localNetwork", title: "Local Network",
            reason: "Widgets that talk to devices on your network (smart home, NAS, printers).",
            group: .privacy, anchor: security + "Privacy_LocalNetwork",
            usageKeys: ["NSLocalNetworkUsageDescription"]
        ),
    ]

    private static let system: [PermissionSpec] = [
        PermissionSpec(
            id: "fullDisk", title: "Full Disk Access",
            reason: "Widgets that read files outside your home folder, such as mail, messages or Safari data.",
            group: .system, anchor: security + "Privacy_AllFiles"
        ),
        PermissionSpec(
            id: "filesFolders", title: "Files & Folders",
            reason: "Widgets that read Desktop, Documents, Downloads or external drives.",
            group: .system, anchor: security + "Privacy_FilesAndFolders",
            usageKeys: [
                "NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                "NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription",
                "NSNetworkVolumesUsageDescription",
            ]
        ),
        PermissionSpec(
            id: "screenRecording", title: "Screen Recording",
            reason: "Only needed to capture the screen itself; ordinary widgets do not need it.",
            group: .system, anchor: security + "Privacy_ScreenCapture"
        ),
        PermissionSpec(
            id: "inputMonitoring", title: "Input Monitoring",
            reason: "Widgets that react to key presses, such as keystroke counters.",
            group: .system, anchor: security + "Privacy_ListenEvent"
        ),
    ]

    private static let automation: [PermissionSpec] = automationTargets.map { target in
        PermissionSpec(
            id: "automation.\(target.bundleID)", title: target.name,
            reason: target.reason,
            group: .automation, anchor: security + "Privacy_Automation",
            usageKeys: ["NSAppleEventsUsageDescription"],
            entitlements: ["com.apple.security.automation.apple-events"],
            automationTarget: target.bundleID
        )
    }
}
