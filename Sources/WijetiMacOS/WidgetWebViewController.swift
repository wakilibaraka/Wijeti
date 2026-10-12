import AppKit
import Foundation
import WebKit

/// Hosts one widget web view and speaks the two message-handler channels the widget
/// client expects. Ported from `UBWebViewController`.
final class WidgetWebViewController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView

    var onOpenExternal: ((URL) -> Void)?
    var onLoadFinished: (() -> Void)?
    var onLoadFailure: ((Error) -> Void)?

    private let geolocation = GeolocationBridge()
    private var mainURL: URL?
    private weak var window: NSWindow?

    init(argvPath: String) {
        let controller = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        controller.add(self, name: "uebersicht")
        controller.add(geolocation, name: "geolocation")
        controller.addUserScript(
            WKUserScript(source: uebersichtGeolocationScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        // Old widgets shell out through `process.argv[0]`, which does not exist in a
        // browser. `UBWebViewController` injected the same shim.
        controller.addUserScript(
            WKUserScript(
                source: "process = {argv: ['\(WidgetWebViewController.escapeForJavaScript(argvPath))']};",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        webView.navigationDelegate = self
        // A transparent web view is what lets widgets float on the wallpaper, and macOS offers
        // no public API for it. `underPageBackgroundColor` is *not* a substitute — it only
        // paints the area behind the page, and substituting it here was measured leaving the
        // widget layer 100% opaque, which would put an opaque sheet over the desktop. The
        // private key is therefore used deliberately, and the supported property is set too
        // for the overscroll area.
        //
        // This is verified rather than assumed: `--snapshot-dir` writes the composited widget
        // layer as a PNG, and its transparent fraction is the regression check for this line.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // A widget that throws leaves a blank, transparent window with nothing to read in
        // the log. Surfacing the message in the title means `page probe` below reports it.
        controller.addUserScript(WKUserScript(
            source: "window.addEventListener('error', function (e) { document.title = 'jserror: ' + e.message; });",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    /// `window` is the desktop window (nil in the in-app preview, where mouse-event
    /// toggling has no meaning — the preview is a normal view, not an overlay).
    func load(url: URL, in window: NSWindow? = nil) {
        mainURL = url
        self.window = window
        webView.load(URLRequest(url: url))
    }

    func reload() {
        guard let mainURL else { return }
        webView.load(URLRequest(url: mainURL))
    }

    /// Nudges WebKit to repaint, which a transparent desktop-level window otherwise skips
    /// when the wallpaper or Space changes underneath it (`-[UBWebViewController redraw]`).
    func forceRedraw() {
        webView.evaluateJavaScript(
            "document.documentElement.style.transform = 'scale(1)';" +
            "requestAnimationFrame(function() { document.documentElement.style.transform = ''; });"
        )
    }

    func snapshot(completion: @escaping (NSImage?) -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in
            completion(image)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "uebersicht", let body = message.body as? String else { return }
        switch body {
        case "widgetEnter":
            window?.ignoresMouseEvents = false
        case "widgetLeave":
            window?.ignoresMouseEvents = true
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("loaded %@", webView.url?.absoluteString ?? "")
        // `readyState|childNodes|htmlLength|title`. A child count of 0 means the widget client
        // received no widgets — the server could not bundle them, or no widget is visible on
        // this screen/layer.
        // The trailing field is the only way to see, from a log, whether the widget page is
        // actually being told the system is in dark mode — which is what widget CSS keys off
        // via `prefers-color-scheme`, and which there is no other way to assert.
        webView.evaluateJavaScript(
            "[document.readyState, document.body ? document.body.children.length : -1,"
                + " document.body ? document.body.innerHTML.length : -1, document.title,"
                + " window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light']"
                + ".join('|')"
        ) { value, error in
            // NSLog's C variadics are unavailable inside this escaping closure; interpolate.
            let appearance = NSApp.effectiveAppearance.name.rawValue
            NSLog("%@", "page probe: \(value ?? "nil") appearance=\(appearance) \(error?.localizedDescription ?? "")")
        }
        onLoadFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                onOpenExternal?(url)
            }
            decisionHandler(.cancel)
        } else if navigationAction.request.url == mainURL {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    private func handleLoadFailure(_ error: Error) {
        NSLog("error loading webview: %@", error.localizedDescription)
        onLoadFailure?(error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.reload()
        }
    }

    private static func escapeForJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
