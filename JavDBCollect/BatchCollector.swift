import UIKit
import WebKit

struct BatchCollectItem {
    let javdbID: String
    let url: URL
}

struct BatchCollectSummary {
    let total: Int
    var added = 0
    var alreadyCollected = 0
    var vrSkipped = 0
    var tooSmall = 0
    var filtered = 0
    var failed = 0

    var processed: Int { added + alreadyCollected + vrSkipped + tooSmall + filtered + failed }
}

final class BatchCollector: NSObject, WKNavigationDelegate {
    private let store: CollectionStore
    private let webView: WKWebView
    private var items: [BatchCollectItem] = []
    private var currentIndex = 0
    private var parseAttempt = 0
    private var summary = BatchCollectSummary(total: 0)
    private var onProgress: ((Int, Int) -> Void)?
    private var onCompletion: ((BatchCollectSummary) -> Void)?
    private(set) var isRunning = false

    init(parentView: UIView, store: CollectionStore, scriptSource: String) {
        self.store = store
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: -1000, y: -1000, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        parentView.addSubview(webView)
    }

    func start(items: [BatchCollectItem], onProgress: @escaping (Int, Int) -> Void, completion: @escaping (BatchCollectSummary) -> Void) -> Bool {
        guard !isRunning, !items.isEmpty else { return false }
        self.items = items
        currentIndex = 0
        parseAttempt = 0
        summary = BatchCollectSummary(total: items.count)
        self.onProgress = onProgress
        onCompletion = completion
        isRunning = true
        onProgress(0, items.count)
        processCurrent()
        return true
    }

    private func processCurrent() {
        guard isRunning else { return }
        guard currentIndex < items.count else { finish(); return }
        let item = items[currentIndex]
        if store.contains(javdbID: item.javdbID) {
            summary.alreadyCollected += 1
            completeCurrent()
            return
        }
        parseAttempt = 0
        webView.stopLoading()
        webView.load(URLRequest(url: item.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    private func attemptParse() {
        guard isRunning else { return }
        parseAttempt += 1
        webView.evaluateJavaScript("window.JavDBCollect && window.JavDBCollect.collectCurrent()") { [weak self] result, _ in
            guard let self, self.isRunning else { return }
            if let json = result as? String, let data = json.data(using: .utf8), let envelope = try? JSONDecoder().decode(ParseEnvelope.self, from: data), let movie = envelope.moviePayload {
                if movie.isVR { self.summary.vrSkipped += 1; self.completeCurrent(); return }
                if movie.candidates.isEmpty && self.parseAttempt < 8 { self.scheduleRetry(); return }
                let sizedCandidates = movie.candidates.filter { $0.sizeGB >= ResourceScorer.minimumSizeGB }
                if sizedCandidates.isEmpty {
                    if movie.candidates.isEmpty { self.summary.filtered += 1 }
                    else { self.summary.tooSmall += 1 }
                    self.completeCurrent()
                    return
                }
                guard let scored = ResourceScorer.best(from: sizedCandidates) else { self.summary.filtered += 1; self.completeCurrent(); return }
                if self.store.add(movie: movie, magnet: scored.candidate.magnet) { self.summary.added += 1 }
                else if self.store.contains(javdbID: movie.javdbId) { self.summary.alreadyCollected += 1 }
                else { self.summary.failed += 1 }
                self.completeCurrent()
                return
            }
            if self.parseAttempt < 8 { self.scheduleRetry() }
            else { self.summary.failed += 1; self.completeCurrent() }
        }
    }

    private func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.attemptParse() }
    }

    private func completeCurrent() {
        currentIndex += 1
        onProgress?(summary.processed, summary.total)
        DispatchQueue.main.async { [weak self] in self?.processCurrent() }
    }

    private func finish() {
        isRunning = false
        webView.stopLoading()
        let result = summary
        let completion = onCompletion
        onProgress = nil
        onCompletion = nil
        completion?(result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.attemptParse() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard isRunning else { return }
        summary.failed += 1
        completeCurrent()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard isRunning else { return }
        summary.failed += 1
        completeCurrent()
    }
}
