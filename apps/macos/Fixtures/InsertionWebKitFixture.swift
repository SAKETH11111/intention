import AppKit
import WebKit

// A window that shows one local page in a WKWebView, for the insertion
// checks: WebKit's web content as Safari shows it, in an app with no
// accounts, history or other windows. It loads only the fixture page it is
// given, can read no other file, keeps no website data, follows no link
// away from that page and blocks every network request.
@main
@MainActor
final class InsertionWebKitFixture: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var page: URL?

    /// Blocks every network scheme, so a page cannot reach the network even
    /// through an image or a script. One rule for each: these filters take
    /// no alternation.
    private static let offline = ["^https?:", "^wss?:", "^ftp:"]
        .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        .joined(separator: ",")

    static func main() {
        let app = NSApplication.shared
        let delegate = InsertionWebKitFixture()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--fixture-page"), arguments.indices.contains(index + 1) else { exit(2) }
        let page = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        // Only a copy of the insertion page, named as the checks name it.
        guard page.pathExtension == "html", page.lastPathComponent.hasPrefix("insertion-"),
              FileManager.default.isReadableFile(atPath: page.path) else { exit(2) }
        self.page = page
        NSApp.mainMenu = Self.menu()
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "intention-fixture-offline", encodedContentRuleList: "[\(Self.offline)]") { rules, _ in
            Task { @MainActor in
                // Without the block the page is not shown at all.
                guard let rules else { exit(3) }
                self.show(page, blocking: rules)
            }
        }
    }

    private func show(_ page: URL, blocking rules: WKContentRuleList) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        let frame = NSRect(x: 120, y: 80, width: 900, height: 960)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // The checks find the window by the page's name.
        window.title = page.lastPathComponent
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
        // Read access to the page alone, not to the directory it is in.
        view.loadFileURL(page, allowingReadAccessTo: page)
        self.window = window
    }

    /// An Edit menu, which is what turns Command-V into a paste: without
    /// one the key reaches no one.
    private static func menu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(app)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(edit)
        return main
    }

    /// Only the fixture page itself is ever navigated to.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.standardizedFileURL == page ? .allow : .cancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
