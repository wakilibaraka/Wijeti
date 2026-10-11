import AppKit
import Foundation
import WijetiMacOS

/// Walks every bundled preset through the widget library's preview pane and records
/// proof that each one renders — the acceptance check for "every bundled preset
/// actually runs as-is". Writes `report.txt` plus one PNG per preset (in-process
/// `WKWebView` snapshots, so no Screen Recording permission is needed).
@MainActor
final class PresetVerifier {
    private struct Failure: Error {
        let reason: String
    }

    private let library: WidgetLibraryWindow
    private let outputDirectory: URL
    private var lines: [String] = []
    private var failures = 0

    init(library: WidgetLibraryWindow, outputDirectory: URL) {
        self.library = library
        self.outputDirectory = outputDirectory
    }

    func run(presetIDs: [String], completion: @escaping (_ allPassed: Bool) -> Void) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        lines.append("Wijeti preset verification — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("\(presetIDs.count) bundled presets")
        lines.append("")
        guard !presetIDs.isEmpty else {
            finish(completion: completion)
            return
        }
        step(0, of: presetIDs, completion: completion)
    }

    // MARK: - Loop

    private func step(_ index: Int, of ids: [String], completion: @escaping (_ allPassed: Bool) -> Void) {
        guard index < ids.count else {
            snapshotLibraryWindow { [weak self] in self?.finish(completion: completion) }
            return
        }
        let id = ids[index]
        library.selectPreset(id: id)
        NSLog("verify: [%d/%d] %@", index + 1, ids.count, id)
        probe(deadline: Date().addingTimeInterval(25)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let probe):
                let text = probe.text
                    .replacingOccurrences(of: "\n", with: " / ")
                    .replacingOccurrences(of: "\t", with: " ")
                self.lines.append("\(id): OK — \(text)")
                self.snapshotPreview(named: id)
            case .failure(let failure):
                self.failures += 1
                self.lines.append("\(id): FAIL — \(failure.reason)")
                NSLog("verify: %@ FAIL — %@", id, failure.reason)
            }
            // Give the next swap a beat so the old widget has been destroyed before
            // the probe starts looking for the new one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.step(index + 1, of: ids, completion: completion)
            }
        }
    }

    // MARK: - Probing

    private struct Probe {
        let text: String
    }

    /// Polls the preview until the preset's own widget element exists, renders no
    /// error table, and the page reports no uncaught error — or until the deadline.
    private func probe(deadline: Date, completion: @escaping (Result<Probe, Failure>) -> Void) {
        library.probePreview { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let probe):
                if probe.found, !probe.error, !probe.title.hasPrefix("jserror") {
                    completion(.success(Probe(text: probe.text.isEmpty ? "(empty)" : probe.text)))
                    return
                }
                if probe.error {
                    completion(.failure(Failure(reason: "render error: \(self.clean(probe.text))")))
                    return
                }
                if probe.title.hasPrefix("jserror") {
                    completion(.failure(Failure(reason: "javascript error: \(probe.title)")))
                    return
                }
                self.retry(deadline: deadline, last: "widget not in page yet", completion: completion)
            case .failure(let error):
                self.retry(deadline: deadline, last: error.localizedDescription, completion: completion)
            }
        }
    }

    private func retry(deadline: Date, last: String, completion: @escaping (Result<Probe, Failure>) -> Void) {
        if Date() >= deadline {
            completion(.failure(Failure(reason: "timed out — \(last)")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.probe(deadline: deadline, completion: completion)
        }
    }

    private func clean(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " / ").prefix(200))
    }

    // MARK: - Artifacts

    private func snapshotPreview(named id: String) {            library.snapshotPreview { [weak self] image in
                guard let self, let image else { return }
                WindowSnapshot.writePNG(
                    image,
                    to: self.outputDirectory.appendingPathComponent(self.safeName(id) + ".png")
                )
            }
    }

    private func snapshotLibraryWindow(completion: @escaping () -> Void) {
        if let image = library.snapshotWindowImage() {
            WindowSnapshot.writePNG(
                image,
                to: outputDirectory.appendingPathComponent("library-window.png")
            )
        }
        completion()
    }

    private func finish(completion: @escaping (_ allPassed: Bool) -> Void) {
        // `lines` so far: two header lines, one blank, then one entry per preset.
        let entries = max(0, lines.count - 3)
        let passed = entries - failures
        lines.append("")
        lines.append("Summary: \(passed)/\(entries) OK")
        let report = lines.joined(separator: "\n") + "\n"
        try? report.write(
            to: outputDirectory.appendingPathComponent("report.txt"),
            atomically: true,
            encoding: .utf8
        )
        NSLog("preset verification done: %@ failures", String(self.failures))
        completion(failures == 0)
    }

    private func safeName(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

}
