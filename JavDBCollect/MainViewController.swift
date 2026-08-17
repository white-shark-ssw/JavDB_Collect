import UIKit
import WebKit

final class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let store = CollectionStore.shared
    private var webView: WKWebView!
    private let floatingButton = UIButton(type: .system)
    private var collectorScriptSource: String?
    private var floatingCenterXConstraint: NSLayoutConstraint!
    private var floatingCenterYConstraint: NSLayoutConstraint!
    private var floatingDragStartCenter = CGPoint.zero
    private var floatingDragStartTouch = CGPoint.zero
    private var isDraggingFloatingButton = false
    private var didRestoreFloatingButtonPosition = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureWebView()
        configureFloatingButton()
        loadHome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didRestoreFloatingButtonPosition {
            restoreFloatingButtonPosition()
            didRestoreFloatingButtonPosition = true
        }
    }

    deinit { webView?.configuration.userContentController.removeScriptMessageHandler(forName: "javdbCollect") }

    private func configureWebView() {
        let contentController = WKUserContentController()
        if let url = Bundle.main.url(forResource: "javdb_collector", withExtension: "js"), let script = try? String(contentsOf: url) {
            collectorScriptSource = script
            contentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        contentController.add(self, name: "javdbCollect")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureFloatingButton() {
        floatingButton.translatesAutoresizingMaskIntoConstraints = false
        floatingButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.96)
        floatingButton.tintColor = .white
        floatingButton.layer.cornerRadius = 28
        floatingButton.layer.shadowColor = UIColor.black.cgColor
        floatingButton.layer.shadowOpacity = 0.25
        floatingButton.layer.shadowRadius = 5
        floatingButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        floatingButton.setImage(UIImage(systemName: "tray.and.arrow.down.fill"), for: .normal)
        floatingButton.addTarget(self, action: #selector(showFloatingMenu), for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleFloatingButtonLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 20
        longPress.cancelsTouchesInView = true
        floatingButton.addGestureRecognizer(longPress)
        view.addSubview(floatingButton)

        floatingCenterXConstraint = floatingButton.centerXAnchor.constraint(equalTo: view.leadingAnchor)
        floatingCenterYConstraint = floatingButton.centerYAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            floatingButton.widthAnchor.constraint(equalToConstant: 56),
            floatingButton.heightAnchor.constraint(equalToConstant: 56),
            floatingCenterXConstraint,
            floatingCenterYConstraint
        ])
    }

    @objc private func showFloatingMenu() {
        guard !isDraggingFloatingButton else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "采集当前", style: .default) { [weak self] _ in self?.collectCurrentMovie() })
        sheet.addAction(UIAlertAction(title: "采集中心", style: .default) { [weak self] _ in self?.showCollectionCenter() })
        sheet.addAction(UIAlertAction(title: "刷新页面", style: .default) { [weak self] _ in self?.webView.reload() })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = floatingButton
            popover.sourceRect = floatingButton.bounds
        }
        present(sheet, animated: true)
    }

    private func floatingMovementFrame() -> CGRect {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let frame = safe.insetBy(dx: 32, dy: 32)
        return frame.width > 0 && frame.height > 0 ? frame : view.bounds.insetBy(dx: 32, dy: 32)
    }

    private func restoreFloatingButtonPosition() {
        let frame = floatingMovementFrame()
        guard frame.width > 0, frame.height > 0 else { return }
        let defaults = UserDefaults.standard
        let hasSaved = defaults.object(forKey: "jdcFloatingX") != nil && defaults.object(forKey: "jdcFloatingY") != nil
        let x: CGFloat
        let y: CGFloat
        if hasSaved {
            let xr = CGFloat(min(max(defaults.double(forKey: "jdcFloatingX"), 0), 1))
            let yr = CGFloat(min(max(defaults.double(forKey: "jdcFloatingY"), 0), 1))
            x = frame.minX + frame.width * xr
            y = frame.minY + frame.height * yr
        } else {
            x = frame.maxX
            y = frame.maxY
        }
        floatingCenterXConstraint.constant = x
        floatingCenterYConstraint.constant = y
    }

    private func clampedFloatingPoint(_ point: CGPoint) -> CGPoint {
        let frame = floatingMovementFrame()
        return CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
    }

    private func saveFloatingButtonPosition() {
        let frame = floatingMovementFrame()
        guard frame.width > 0, frame.height > 0 else { return }
        let xr = Double((floatingCenterXConstraint.constant - frame.minX) / frame.width)
        let yr = Double((floatingCenterYConstraint.constant - frame.minY) / frame.height)
        UserDefaults.standard.set(min(max(xr, 0), 1), forKey: "jdcFloatingX")
        UserDefaults.standard.set(min(max(yr, 0), 1), forKey: "jdcFloatingY")
    }

    @objc private func handleFloatingButtonLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDraggingFloatingButton = true
            floatingDragStartCenter = CGPoint(x: floatingCenterXConstraint.constant, y: floatingCenterYConstraint.constant)
            floatingDragStartTouch = gesture.location(in: view)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIView.animate(withDuration: 0.12) { self.floatingButton.transform = CGAffineTransform(scaleX: 1.08, y: 1.08) }
        case .changed:
            let touch = gesture.location(in: view)
            let target = CGPoint(x: floatingDragStartCenter.x + touch.x - floatingDragStartTouch.x, y: floatingDragStartCenter.y + touch.y - floatingDragStartTouch.y)
            let point = clampedFloatingPoint(target)
            floatingCenterXConstraint.constant = point.x
            floatingCenterYConstraint.constant = point.y
        case .ended, .cancelled, .failed:
            saveFloatingButtonPosition()
            isDraggingFloatingButton = false
            UIView.animate(withDuration: 0.16) { self.floatingButton.transform = .identity }
        default:
            break
        }
    }

    private func loadHome() {
        guard let url = URL(string: "https://javdb.com/") else { return }
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    private func ensureCollectorScript(_ completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("typeof window.JavDBCollect !== 'undefined'") { [weak self] result, _ in
            if (result as? Bool) == true { completion(true); return }
            guard let self, let script = self.collectorScriptSource, !script.isEmpty else { completion(false); return }
            self.webView.evaluateJavaScript(script) { _, error in completion(error == nil) }
        }
    }

    private func collectCurrentMovie() {
        ensureCollectorScript { [weak self] ready in
            guard let self else { return }
            guard ready else {
                self.showAlert(title: "采集脚本未加载", message: "采集脚本没有进入 App 包或网页注入失败，请安装最新版本后重试。")
                return
            }
            self.webView.evaluateJavaScript("window.JavDBCollect.collectCurrent()") { [weak self] result, error in
                guard let self else { return }
                if let error { self.showAlert(title: "采集失败", message: error.localizedDescription); return }
                guard let json = result as? String, let data = json.data(using: .utf8), let envelope = try? JSONDecoder().decode(ParseEnvelope.self, from: data) else {
                    self.showAlert(title: "采集失败", message: "无法解析当前页面。")
                    return
                }
                if let error = envelope.error {
                    let message = error == "not_detail_page" ? "请先进入一个影片详情页。" : "页面采集脚本未就绪。"
                    self.showAlert(title: "无法采集", message: message)
                    return
                }
                guard let movie = envelope.moviePayload else { self.showAlert(title: "采集失败", message: "影片信息不完整。"); return }
                if self.store.contains(javdbID: movie.javdbId) {
                    self.showToast("✓ 已采集过 \(movie.code)")
                    self.refreshCollectedMarks()
                    return
                }
                guard let scored = ResourceScorer.best(from: movie.candidates) else {
                    self.showAlert(title: "没有可用磁链", message: "没有找到符合规则的资源，或候选资源均被 ISO/原盘规则排除。")
                    return
                }
                guard self.store.add(movie: movie, magnet: scored.candidate.magnet) else {
                    self.showAlert(title: "保存失败", message: "无法写入本地采集数据库。")
                    return
                }
                let detail = scored.candidate.meta.isEmpty ? scored.candidate.name : scored.candidate.meta
                self.showToast("✓ 已采集 \(movie.code)\n\(detail)")
                self.refreshCollectedMarks()
            }
        }
    }

    private func showCollectionCenter() {
        let controller = CollectionCenterViewController(store: store)
        controller.onDatabaseChanged = { [weak self] in self?.refreshCollectedMarks() }
        let navigation = UINavigationController(rootViewController: controller)
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(navigation, animated: true)
    }

    private func refreshCollectedMarks() {
        ensureCollectorScript { [weak self] ready in
            guard ready else { return }
            self?.webView.evaluateJavaScript("window.JavDBCollect.reportVisible()")
        }
    }

    private func applyCollected(ids: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ids), let json = String(data: data, encoding: .utf8) else { return }
        ensureCollectorScript { [weak self] ready in
            guard ready else { return }
            self?.webView.evaluateJavaScript("window.JavDBCollect.applyCollected(\(json))")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "javdbCollect", let body = message.body as? [String: Any], body["type"] as? String == "visibleMovies", let ids = body["ids"] as? [String] else { return }
        applyCollected(ids: store.collectedIDs(for: ids))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refreshCollectedMarks() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    private func showToast(_ text: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = "  \(text)  "
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: floatingButton.topAnchor, constant: -16),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        label.alpha = 0
        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.6, options: [.curveEaseInOut], animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
        }
    }
}
