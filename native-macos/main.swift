// wirejac — native macOS shell (WKWebView).
// A real .app: own process, own Dock/Launchpad icon, no Chrome. Serves the
// bundled PWA (Contents/Resources/dist) on a free loopback port via python3,
// reads the server's port from its startup line (no load race), and renders it
// in a native WKWebView. Writes a debug log to /tmp/wirejac.log.

import Cocoa
import WebKit

let LOG = URL(fileURLWithPath: "/tmp/wirejac.log")

func log(_ s: String) {
    let line = s + "\n"
    if let h = try? FileHandle(forWritingTo: LOG) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: LOG)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var server: Process?
    var port: Int = 0
    var loaded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? "".data(using: .utf8)!.write(to: LOG)   // truncate log
        log("launch \(Date())")

        let distURL = Bundle.main.resourceURL!.appendingPathComponent("dist")
        log("dist path: \(distURL.path) exists=\(FileManager.default.fileExists(atPath: distURL.appendingPathComponent("index.html").path))")

        let rect = NSRect(x: 0, y: 0, width: 1320, height: 880)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "wirejac"
        window.minSize = NSSize(width: 1000, height: 700)
        window.center()

        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: rect, configuration: cfg)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // "Starting…" placeholder so it's never a mystery blank.
        webView.loadHTMLString("<html><body style='font-family:-apple-system;background:#fff;color:#888;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'>starting wirejac…</body></html>", baseURL: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-u", "-m", "http.server", "0",
                       "--bind", "127.0.0.1", "--directory", distURL.path]
        // Python's http.server prints "Serving HTTP on ... port N" to STDOUT;
        // request logs go to STDERR. Merge both into one pipe so we always catch it.
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self = self else { return }
            let s = String(data: fh.availableData, encoding: .utf8) ?? ""
            if !s.isEmpty { log("server: \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
            if self.port == 0, let r = s.range(of: "port ") {
                let digits = s[r.upperBound...].prefix(while: { $0.isNumber })
                if let n = Int(digits) {
                    self.port = n
                    log("parsed port: \(n)")
                    DispatchQueue.main.async { self.loadApp() }
                }
            }
        }
        do { try p.run(); log("python launched") } catch { log("python FAILED: \(error)") }
        server = p
    }

    func loadApp() {
        guard port != 0 else { return }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        log("loadApp -> \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log("didStartProvisional \(webView.url?.absoluteString ?? "")")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.scheme == "http" { loaded = true; log("didFinish \(webView.url?.absoluteString ?? "")") }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail: \(error.localizedDescription)")
        showError(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("didFailProvisional: \(error.localizedDescription)")
        if loaded { return }
        // retry a few times (server may still be starting), then surface the error
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.loadApp() }
    }
    func showError(_ error: Error) {
        let html = "<html><body style='font-family:-apple-system;padding:24px;color:#b00'>Load error: \(error.localizedDescription)<br>port=\(port)</body></html>"
        webView.loadHTMLString(html, baseURL: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { server?.terminate() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
