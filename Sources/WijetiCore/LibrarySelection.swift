import Foundation

/// Which widgets are selected in the library, independent of any UI.
///
/// Items are identified by a stable key (a bundled preset id, or an imported widget's folder
/// name). `anchor` remembers the last item clicked so a Shift-click can select the range
/// between it and the new item, in whatever order the list is currently showing.
public struct LibrarySelection: Equatable, Sendable {
    public private(set) var keys: Set<String> = []
    public private(set) var anchor: String?

    public init() {}

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public func contains(_ key: String) -> Bool { keys.contains(key) }

    /// ⌘-click: flip one item and make it the new anchor.
    public mutating func toggle(_ key: String) {
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        anchor = key
    }

    /// Plain click: select only this item.
    public mutating func select(only key: String) {
        keys = [key]
        anchor = key
    }

    /// ⇧-click: add everything between the anchor and `key` in `visible` order. Without an
    /// anchor (or if it is no longer visible) this behaves like a plain toggle.
    public mutating func extend(to key: String, in visible: [String]) {
        guard let anchor,
              let from = visible.firstIndex(of: anchor),
              let to = visible.firstIndex(of: key)
        else {
            toggle(key)
            return
        }
        keys.formUnion(visible[min(from, to)...max(from, to)])
    }

    public mutating func selectAll(_ visible: [String]) {
        keys = Set(visible)
        anchor = visible.last
    }

    public mutating func clear() {
        keys = []
        anchor = nil
    }

    /// Drops keys that are no longer in the library (after a removal or a filter that hides them).
    public mutating func retain(only valid: Set<String>) {
        keys.formIntersection(valid)
        if let anchor, !valid.contains(anchor) { self.anchor = nil }
    }
}
