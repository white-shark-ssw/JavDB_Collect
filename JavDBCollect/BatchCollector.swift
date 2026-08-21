import UIKit
import WebKit

struct BatchCollectItem: Codable {
    let javdbID: String
    let url: URL
}

struct BatchCollectSummary: Codable {
    let total: Int
    var added = 0
    var alreadyCollected = 0
    var vrSkipped = 0
    var tooSmall = 0
    var filtered = 0
    var failed = 0

    var processed: Int { added + alreadyCollected + vrSkipped + tooSmall + filtered + failed }
}

private enum BatchWorkerResult {
    case movie(MoviePayload)
    case failed
}

private final class BatchWorker: NSObject, WKNavigationDelegate {
    let index: Int
    let webView: WKWebView
    private(set) var currentItem: BatchCollectItem?
    private var completion: ((BatchWorker, BatchCollectItem, BatchWorkerResult) -> Void)?
    private var parseAttempt = 0
    private var generation = 0

    init(index: Int, parentView: UIView, scriptSource: String) {
        self.index = index
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: CGFloat(-1200 - index * 10), y: -1200, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        parentView.addSubview(webView)
    }

    func start(item: BatchCollectItem, completion: @escaping (BatchWorker, BatchCollectItem, BatchWorkerResult) -> Void) {
        guard currentItem == nil else { return }
        generation += 1
        let currentGeneration = generation
        currentItem = item
        self.completion = completion
        parseAttempt = 0
        webView.stopLoading()
        webView.load(URLRequest(url: item.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, self.currentItem != nil, self.generation == currentGeneration else { return }
            self.finish(.failed, generation: currentGeneration)
        }
    }

    func cancel() {
        generation += 1
        currentItem = nil
        completion = nil
        parseAttempt = 0
        webView.stopLoading()
    }

    private func attemptParse(generation currentGeneration: Int) {
        guard currentItem != nil, generation == currentGeneration else { return }
        parseAttempt += 1
        webView.evaluateJavaScript("window.JavDBCollect && window.JavDBCollect.collectCurrent()") { [weak self] result, _ in
            guard let self, self.currentItem != nil, self.generation == currentGeneration else { return }
            if let json = result as? String, let data = json.data(using: .utf8), let envelope = try? JSONDecoder().decode(ParseEnvelope.self, from: data), let movie = envelope.moviePayload {
                if movie.candidates.isEmpty && self.parseAttempt < 8 { self.scheduleRetry(generation: currentGeneration); return }
                self.finish(.movie(movie), generation: currentGeneration)
                return
            }
            if self.parseAttempt < 8 { self.scheduleRetry(generation: currentGeneration) }
            else { self.finish(.failed, generation: currentGeneration) }
        }
    }

    private func scheduleRetry(generation currentGeneration: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.attemptParse(generation: currentGeneration) }
    }

    private func finish(_ result: BatchWorkerResult, generation currentGeneration: Int) {
        guard generation == currentGeneration, let item = currentItem else { return }
        currentItem = nil
        let callback = completion
        completion = nil
        parseAttempt = 0
        webView.stopLoading()
        callback?(self, item, result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard currentItem != nil else { return }
        let currentGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.attemptParse(generation: currentGeneration) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard currentItem != nil else { return }
        finish(.failed, generation: generation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard currentItem != nil else { return }
        finish(.failed, generation: generation)
    }
}

final class BatchCollector: NSObject {
    private struct PersistedState: Codable {
        let pending: [BatchCollectItem]
        let inFlight: [BatchCollectItem]
        let summary: BatchCollectSummary
    }

    private static let persistenceKey = "jdcBatchCollectorStateV1"
    private let store: CollectionStore
    private let workers: [BatchWorker]
    private var pending: [BatchCollectItem] = []
    private var summary = BatchCollectSummary(total: 0)
    private var onProgress: ((Int, Int) -> Void)?
    private var onCompletion: ((BatchCollectSummary) -> Void)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var isRunning = false
    private(set) var isPaused = false
    var hasTask: Bool { isRunning || isPaused }

    static var hasPersistedTask: Bool {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey), let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return false }
        return state.summary.processed < state.summary.total && (!state.pending.isEmpty || !state.inFlight.isEmpty)
    }

    init(parentView: UIView, store: CollectionStore, scriptSource: String, concurrency: Int = 3) {
        self.store = store
        let workerCount = max(1, min(concurrency, 4))
        workers = (0..<workerCount).map { BatchWorker(index: $0, parentView: parentView, scriptSource: scriptSource) }
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
    }

    func start(items: [BatchCollectItem], onProgress: @escaping (Int, Int) -> Void, completion: @escaping (BatchCollectSummary) -> Void) -> Bool {
        guard !hasTask, !items.isEmpty else { return false }
        pending = deduplicated(items)
        summary = BatchCollectSummary(total: pending.count)
        self.onProgress = onProgress
        onCompletion = completion
        isRunning = true
        isPaused = false
        persistState()
        onProgress(0, summary.total)
        scheduleWork()
        return true
    }

    func resumePersisted(onProgress: @escaping (Int, Int) -> Void, completion: @escaping (BatchCollectSummary) -> Void) -> Bool {
        guard !hasTask, let data = UserDefaults.standard.data(forKey: Self.persistenceKey), let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return false }
        pending = deduplicated(state.inFlight + state.pending)
        summary = state.summary
        if pending.isEmpty || summary.processed >= summary.total { Self.clearPersistedState(); return false }
        self.onProgress = onProgress
        onCompletion = completion
        isRunning = true
        isPaused = false
        persistState()
        onProgress(summary.processed, summary.total)
        scheduleWork()
        return true
    }

    func pauseForBackgroundExpiration() {
        guard isRunning else { return }
        let active = workers.compactMap(\.currentItem)
        workers.forEach { $0.cancel() }
        pending = deduplicated(active + pending)
        isRunning = false
        isPaused = true
        persistState()
    }

    func resumePaused() {
        guard isPaused else { return }
        isPaused = false
        isRunning = true
        onProgress?(summary.processed, summary.total)
        persistState()
        scheduleWork()
    }

    private func scheduleWork() {
        guard isRunning else { return }
        for worker in workers where worker.currentItem == nil {
            while !pending.isEmpty {
                let item = pending.removeFirst()
                if store.contains(javdbID: item.javdbID) {
                    summary.alreadyCollected += 1
                    onProgress?(summary.processed, summary.total)
                    continue
                }
                worker.start(item: item) { [weak self] worker, item, result in self?.worker(worker, completed: item, result: result) }
                break
            }
        }
        persistState()
        if pending.isEmpty && workers.allSatisfy({ $0.currentItem == nil }) { finish() }
    }

    private func worker(_ worker: BatchWorker, completed item: BatchCollectItem, result: BatchWorkerResult) {
        guard isRunning else { return }
        switch result {
        case .failed:
            summary.failed += 1
        case .movie(let movie):
            if store.contains(javdbID: movie.javdbId) { summary.alreadyCollected += 1 }
            else if movie.isVR { summary.vrSkipped += 1 }
            else {
                let sizedCandidates = movie.candidates.filter { $0.sizeGB >= ResourceScorer.minimumSizeGB }
                if sizedCandidates.isEmpty {
                    if movie.candidates.isEmpty { summary.filtered += 1 }
                    else { summary.tooSmall += 1 }
                } else if let scored = ResourceScorer.best(from: sizedCandidates) {
                    if store.add(movie: movie, magnet: scored.candidate.magnet) { summary.added += 1 }
                    else if store.contains(javdbID: movie.javdbId) { summary.alreadyCollected += 1 }
                    else { summary.failed += 1 }
                } else { summary.filtered += 1 }
            }
        }
        onProgress?(summary.processed, summary.total)
        persistState()
        scheduleWork()
    }

    private func finish() {
        guard hasTask else { return }
        workers.forEach { $0.cancel() }
        isRunning = false
        isPaused = false
        endBackgroundTask()
        Self.clearPersistedState()
        let result = summary
        let completion = onCompletion
        onProgress = nil
        onCompletion = nil
        pending.removeAll()
        completion?(result)
    }

    private func deduplicated(_ items: [BatchCollectItem]) -> [BatchCollectItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.javdbID).inserted }
    }

    private func persistState() {
        guard hasTask else { return }
        let state = PersistedState(pending: pending, inFlight: workers.compactMap(\.currentItem), summary: summary)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.persistenceKey) }
    }

    private static func clearPersistedState() { UserDefaults.standard.removeObject(forKey: persistenceKey) }

    @objc private func appDidEnterBackground() {
        guard isRunning, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "JavDBBatchCollect") { [weak self] in
            guard let self else { return }
            self.pauseForBackgroundExpiration()
            self.endBackgroundTask()
        }
    }

    @objc private func appWillEnterForeground() {
        endBackgroundTask()
        if isPaused { resumePaused() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
