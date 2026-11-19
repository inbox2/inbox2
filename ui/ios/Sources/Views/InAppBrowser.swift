import SwiftUI
import WebKit

/// A link tapped in an email body, wrapped so it can drive a `.fullScreenCover(item:)`.
struct BrowserLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// An in-app browser presented when a link is tapped in an email body — the iOS
/// counterpart of the desktop in-app browser tab (BrowserChrome). Links open here
/// instead of leaving for Safari, so the reader stays inside inbox2. Featureset
/// mirrors the desktop toolbar: back / forward / reload-stop / address (lock + host)
/// / share / open-in-system / close, with a thin load-progress bar.
struct InAppBrowser: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BrowserWebModel()
    let url: URL
    private var p: ThemePalette { theme.palette }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .top) {
                BrowserWebHost(webView: model.webView)
                if model.isLoading {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(LinearGradient(colors: p.ringColors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * max(0.04, model.progress), height: 2)
                            .animation(.easeOut(duration: 0.2), value: model.progress)
                    }
                    .frame(height: 2)
                }
            }
        }
        .background(p.bgBase.ignoresSafeArea())
        .onAppear { model.load(url) }
    }

    private var toolbar: some View {
        HStack(spacing: Space.s3) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(AppFont.base(.semibold))
            }

            Button { model.webView.goBack() } label: {
                Image(systemName: "chevron.left").font(AppFont.title3)
            }
            .disabled(!model.canGoBack)
            .opacity(model.canGoBack ? 1 : 0.35)

            Button { model.webView.goForward() } label: {
                Image(systemName: "chevron.right").font(AppFont.title3)
            }
            .disabled(!model.canGoForward)
            .opacity(model.canGoForward ? 1 : 0.35)

            addressField

            Button {
                if model.isLoading { model.webView.stopLoading() } else { model.webView.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise").font(AppFont.base(.semibold))
            }

            Menu {
                if let u = model.currentURL ?? Optional(url) {
                    ShareLink(item: u) { Label("Share…", systemImage: "square.and.arrow.up") }
                    Button { UIApplication.shared.open(u) } label: { Label("Open in Safari", systemImage: "safari") }
                    Button { UIPasteboard.general.string = u.absoluteString } label: { Label("Copy link", systemImage: "doc.on.doc") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(AppFont.body)
            }
        }
        .foregroundStyle(p.accentViolet)
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2 + 2)
        .background(p.bgSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 1) }
    }

    /// Domain-only address display (lock for https) — like the desktop chrome, which
    /// shows `domainOf(url)` with the full URL in the tooltip.
    private var addressField: some View {
        let current = model.currentURL ?? url
        let secure = current.scheme?.lowercased() == "https"
        return HStack(spacing: 5) {
            Image(systemName: secure ? "lock.fill" : "globe")
                .font(AppFont.glyph(10))
                .foregroundStyle(secure ? p.textSecondary : p.textTertiary)
            Text(host(current))
                .font(AppFont.xs)
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(Capsule().fill(p.bgRaised))
    }

    private func host(_ u: URL) -> String {
        (u.host ?? u.absoluteString).replacingOccurrences(of: "www.", with: "")
    }
}

/// Owns the browser `WKWebView` and republishes its KVO state for the SwiftUI chrome.
final class BrowserWebModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL: URL?
    @Published var progress: Double = 0

    private var observers: [NSKeyValueObservation] = []
    private var loaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // real cookies/localStorage, like a browser
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        observers = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in self?.isLoading = wv.isLoading },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in self?.currentURL = wv.url },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in self?.progress = wv.estimatedProgress },
        ]
    }

    /// Load once — `onAppear` can fire again after a back-gesture push; don't reset.
    func load(_ url: URL) {
        guard !loaded else { return }
        loaded = true
        webView.load(URLRequest(url: url))
    }
}

/// Hosts the model's `WKWebView` (created once, outside SwiftUI's view recycling).
private struct BrowserWebHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
