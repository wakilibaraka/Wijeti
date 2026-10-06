import Foundation

/// A widget as reported by `GET /state/` on the widget server.
public struct WidgetDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var filePath: String
    public var mtime: String

    public init(id: String, filePath: String, mtime: String) {
        self.id = id
        self.filePath = filePath
        self.mtime = mtime
    }
}

/// Per-widget display settings. Every field defaults so that a partial payload — the
/// server only writes the keys that differ from its own defaults — still decodes.
///
/// The defaults **must** mirror `defaultSettings` in `server/src/reducer.js`. They are
/// load-bearing: `render.js` only shows a widget when `showOnAllScreens` is true (or all
/// three screen flags are unset in its own terms), so a host that defaults it to `false`
/// makes every widget invisible the first time it writes any setting at all.
public struct WidgetSettings: Codable, Equatable, Sendable {
    public var showOnAllScreens: Bool
    public var showOnMainScreen: Bool
    public var showOnSelectedScreens: Bool
    public var hidden: Bool
    public var screens: [Int]

    /// Widgets in the background layer render into the desktop-level window; the rest
    /// render above other applications (`render.js` `isInBackground`).
    public var inBackground: Bool

    public init(
        showOnAllScreens: Bool = true,
        showOnMainScreen: Bool = false,
        showOnSelectedScreens: Bool = false,
        hidden: Bool = false,
        screens: [Int] = [],
        inBackground: Bool = false
    ) {
        self.inBackground = inBackground
        self.showOnAllScreens = showOnAllScreens
        self.showOnMainScreen = showOnMainScreen
        self.showOnSelectedScreens = showOnSelectedScreens
        self.hidden = hidden
        self.screens = screens
    }

    private enum CodingKeys: String, CodingKey {
        case showOnAllScreens, showOnMainScreen, showOnSelectedScreens, hidden, screens, inBackground
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showOnAllScreens = try container.decodeIfPresent(Bool.self, forKey: .showOnAllScreens) ?? true
        showOnMainScreen = try container.decodeIfPresent(Bool.self, forKey: .showOnMainScreen) ?? false
        showOnSelectedScreens = try container.decodeIfPresent(Bool.self, forKey: .showOnSelectedScreens) ?? false
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        screens = try container.decodeIfPresent([Int].self, forKey: .screens) ?? []
        inBackground = try container.decodeIfPresent(Bool.self, forKey: .inBackground) ?? false
    }

    /// Plain dictionary form, for sending over the server's message bus.
    public var dictionary: [String: Any] {
        [
            "showOnAllScreens": showOnAllScreens,
            "showOnMainScreen": showOnMainScreen,
            "showOnSelectedScreens": showOnSelectedScreens,
            "hidden": hidden,
            "screens": screens,
            "inBackground": inBackground,
        ]
    }

    /// Mirrors `isVisibleOnScreen` in `server/src/render.js`: a widget is shown when it is
    /// not hidden and one of the three screen flags wins. Note the fall-through is
    /// *invisible*, not visible — that asymmetry is what the server does, and why the
    /// defaults above matter.
    public func isVisible(onScreen screen: Int) -> Bool {
        if hidden { return false }
        if showOnAllScreens { return true }
        if showOnMainScreen { return screen == 1 }
        if showOnSelectedScreens { return screens.contains(screen) }
        return false
    }
}

/// The full body of `GET /state/`.
public struct WidgetStateResponse: Codable, Equatable, Sendable {
    public var widgets: [String: WidgetDescriptor]
    public var settings: [String: WidgetSettings]
    public var screens: [Int]

    public init(
        widgets: [String: WidgetDescriptor],
        settings: [String: WidgetSettings],
        screens: [Int]
    ) {
        self.widgets = widgets
        self.settings = settings
        self.screens = screens
    }

    private enum CodingKeys: String, CodingKey {
        case widgets, settings, screens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        widgets = try container.decodeIfPresent([String: WidgetDescriptor].self, forKey: .widgets) ?? [:]
        settings = try container.decodeIfPresent([String: WidgetSettings].self, forKey: .settings) ?? [:]
        screens = try container.decodeIfPresent([Int].self, forKey: .screens) ?? []
    }

    public func settings(for widgetID: String) -> WidgetSettings {
        settings[widgetID] ?? WidgetSettings()
    }

    public static func fetch(from url: URL, session: URLSession = .shared) async throws -> WidgetStateResponse {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(WidgetStateResponse.self, from: data)
    }
}
