import XCTest
@testable import WijetiCore

final class PermissionCatalogTests: XCTestCase {
    private func resource(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/\(name)"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    func testIdsAreUnique() {
        let ids = PermissionCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEveryEntryHasTitleAndReason() {
        for spec in PermissionCatalog.all {
            XCTAssertFalse(spec.title.isEmpty, spec.id)
            XCTAssertFalse(spec.reason.isEmpty, spec.id)
        }
    }

    func testEveryUsageKeyIsInInfoPlist() throws {
        let plist = try resource("Info.plist")
        for spec in PermissionCatalog.all {
            for key in spec.usageKeys {
                XCTAssertNotNil(plist[key], "\(spec.id) needs \(key) in Info.plist")
            }
        }
    }

    func testEveryEntitlementIsGranted() throws {
        let entitlements = try resource("Wijeti.entitlements")
        for spec in PermissionCatalog.all {
            for key in spec.entitlements {
                XCTAssertEqual(entitlements[key] as? Bool, true, "\(spec.id) needs \(key)")
            }
        }
    }

    func testLibraryValidationStaysDisabled() throws {
        let entitlements = try resource("Wijeti.entitlements")
        XCTAssertEqual(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool, true)
    }

    func testAutomationEntriesTargetAnApp() {
        let automation = PermissionCatalog.specs(in: .automation)
        XCTAssertFalse(automation.isEmpty)
        for spec in automation { XCTAssertNotNil(spec.automationTarget) }
    }

    func testSearchMatchesTitleAndReason() throws {
        let music = try XCTUnwrap(PermissionCatalog.spec(id: "automation.com.apple.Music"))
        XCTAssertTrue(music.matches("music"))
        XCTAssertTrue(music.matches("  "))
        XCTAssertFalse(music.matches("zzzz"))
    }
}
