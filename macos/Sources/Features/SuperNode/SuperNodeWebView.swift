import AppKit
import WebKit

/// A web page on the canvas: a dev server's preview beside the terminal
/// running it, docs, or a video.
final class SuperNodeWebView: SuperNodeNodeView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    private let webView: WKWebView
    private let addressField = NSTextField()
    private let backButton: NSButton
    private let forwardButton: NSButton
    private var observations: [NSKeyValueObservation] = []

    static let toolbarHeight: CGFloat = 30

    override init(item: SuperNodeItem) {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        backButton = SuperNodeHeaderView.button(symbol: "chevron.left", tooltip: "Back", target: nil, action: nil)
        forwardButton = SuperNodeHeaderView.button(symbol: "chevron.right", tooltip: "Forward", target: nil, action: nil)
        super.init(item: item)
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        backButton.target = webView
        backButton.action = #selector(WKWebView.goBack(_:))
        forwardButton.target = webView
        forwardButton.action = #selector(WKWebView.goForward(_:))
        let reload = SuperNodeHeaderView.button(symbol: "arrow.clockwise", tooltip: "Reload", target: webView, action: #selector(WKWebView.reload(_:)))

        addressField.placeholderString = "Enter a URL, or localhost:3000"
        addressField.font = .systemFont(ofSize: 12)
        addressField.bezelStyle = .roundedBezel
        addressField.controlSize = .small
        addressField.lineBreakMode = .byTruncatingTail
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressEntered)

        let container = SuperNodeWebContainer(buttons: [backButton, forwardButton, reload], address: addressField, webView: webView)
        body = container

        header.addButton(symbol: "safari", tooltip: "Open in your browser", target: self, action: #selector(openInBrowser))

        // Keep the header and buttons in step with the page.
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.refreshHeader() },
            webView.observe(\.url) { [weak self] _, _ in self?.pageDidChange() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.updateButtons() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.updateButtons() },
        ]

        if let url = item.url.flatMap(Self.url(from:)) {
            addressField.stringValue = url.absoluteString
            webView.load(URLRequest(url: url))
        }
        updateButtons()
        refreshHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var defaultTitle: String {
        if let title = webView.title, !title.isEmpty { return title }
        return webView.url?.host ?? "Web"
    }

    override func refreshHeader() {
        super.refreshHeader()
        header.subtitleLabel.stringValue = webView.url.map { url in
            url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
        } ?? ""
    }

    private func pageDidChange() {
        if let url = webView.url?.absoluteString, url != "about:blank" {
            if addressField.currentEditor() == nil { addressField.stringValue = url }
            if url != item.url {
                item.url = url
                canvas?.documentDidChange()
            }
        }
        refreshHeader()
    }

    private func updateButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    /// Opens a page, such as a dev server's address.
    func load(_ string: String) {
        guard let url = Self.url(from: string) else { return }
        addressField.stringValue = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    /// The URL for what was typed: "localhost:3000" and "example.com" get a
    /// scheme, and anything with spaces becomes a search.
    static func url(from string: String) -> URL? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return URL(string: text) }
        if text.contains(" ") || !text.contains(where: { $0 == "." || $0 == ":" }) && text != "localhost" {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: text)]
            return components?.url
        }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("0.0.0.0") || text.hasPrefix("[::1]")
        return URL(string: (local ? "http://" : "https://") + text)
    }

    @objc private func addressEntered() {
        load(addressField.stringValue)
        window?.makeFirstResponder(webView)
    }

    @objc private func openInBrowser() {
        guard let url = webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    // Links that open a new window load here instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    /// A dev server that isn't up yet shows a page that says so.
    private func showError(_ error: Error) {
        let error = error as NSError
        guard error.code != NSURLErrorCancelled else { return }
        let address = (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? addressField.stringValue
        let html = """
        <html><body style="font: 13px -apple-system; color: #888; display: flex; align-items: center;
        justify-content: center; height: 90vh; text-align: center; background: transparent">
        <div><p style="font-size: 15px">Couldn't open \(address.replacingOccurrences(of: "<", with: "&lt;"))</p>
        <p>\(error.localizedDescription.replacingOccurrences(of: "<", with: "&lt;"))</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    override func tearDown() {
        observations = []
        webView.stopLoading()
    }

    /// The WebKit process drawing this page, for the Process Monitor. WebKit
    /// only tells through a private property, so look before asking.
    var contentProcessID: pid_t? {
        let key = "_webProcessIdentifier"
        guard webView.responds(to: NSSelectorFromString(key)),
              let pid = (webView.value(forKey: key) as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }
}

/// The web node's body: a toolbar with the address above the page.
private final class SuperNodeWebContainer: NSView {
    private let buttons: [NSView]
    private let address: NSView
    private let webView: NSView

    init(buttons: [NSView], address: NSView, webView: NSView) {
        self.buttons = buttons
        self.address = address
        self.webView = webView
        super.init(frame: .zero)
        for view in buttons + [address, webView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let height = SuperNodeWebView.toolbarHeight
        var x: CGFloat = 6
        for button in buttons {
            button.frame = NSRect(x: x, y: (height - 20) / 2, width: 20, height: 20)
            x += 22
        }
        let fieldHeight: CGFloat = 22
        address.frame = NSRect(x: x + 4, y: (height - fieldHeight) / 2, width: max(40, bounds.width - x - 10), height: fieldHeight)
        webView.frame = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    }
}
