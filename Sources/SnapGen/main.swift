import Foundation
import WijetiCore
import AppKit

@main
struct SnapGen {
    static func main() {
        let presetsDir: URL
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("presets", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            presetsDir = bundled
        } else {
            presetsDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/presets")
        }
        let catalog = PresetCatalog.load(from: presetsDir)
        print("Catalog loaded: \(catalog.presets.count) presets")
        for p in catalog.presets {
            print("  \(p.id): \(p.title) [\(p.category)]")
        }

        let iconRect = NSRect(x: 2.5, y: 2.5, width: 13, height: 13)
        let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 4, yRadius: 4)
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()
        iconPath.lineWidth = 1.6
        iconPath.stroke()
        iconPath.move(to: NSPoint(x: 6, y: 10))
        iconPath.line(to: NSPoint(x: 12, y: 10))
        iconPath.move(to: NSPoint(x: 6, y: 7.5))
        iconPath.line(to: NSPoint(x: 12, y: 7.5))
        iconPath.stroke()
        image.unlockFocus()
        image.isTemplate = true
        if let png = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: png),
           let data = rep.representation(using: .png, properties: [:]) {
            let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "wijeti-icon.png")
            try? data.write(to: out)
            print("Wrote \(out.path)")
        }
    }
}
