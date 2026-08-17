import UIKit
import WebKit

final class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let store = CollectionStore.shared
    private var webView: WKWebView!
    private let floatingButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureWebView()
        configureFloatingButton()
        loadHome()
    }

    deinit { webView?.configuration.userContentController.removeScriptMessageHandler(forName: "javdbCollect") }

    private func configureWebView() {
        let contentController = WKUserContentController()
        if let url = Bundle.main.url(forResource: "javdb_collector", withExtension: "js"), let script = try? String(contentsOf: url) {
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
        floatingButton.menu = UIMenu(children: [
            UIAction(title: "采集当前", image: UIImage(systemName: "plus.circle.fill")) { [weak self] _ in self?.collectCurrentMovie() },
            UIAction(title: "采集中心", image: UIImage(systemName: "list.bullet.rectangle")) { [weak self] _ in self?.showCollectionCenter() },
            UIAction(title: "刷新页面", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.webView.reload() }
        ])
        floatingButton.showsMenuAsPrimaryAction = true
        view.addSubview(floatingButton)

        NSLayoutConstraint.activate([
            floatingButton.widthAnchor.constraint(equalToConstant: 56),
            floatingButton.heightAnchor.constraint(equalToConstant: 56),
            floatingButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            floatingButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])
    }

    private func loadHome() {
        guard let url = URL(string: "https://javdb.com/") else { return }
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    private func collectCurrentMovie() {
        let script = "window.JavDBCollect ? window.JavDBCollect.collectCurrent() : JSON.stringify({error:'script_missing'})"
        webView.evaluateJavaScript(script) { [weak self] result, error in
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

    private func showCollectionCenter() {
        let controller = CollectionCenterViewController(store: store)
        controller.onDatabaseChanged = { [weak self] in self?.refreshCollectedMarks() }
        let navigation = UINavigationController(rootViewController: controller)
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(navigation, animated: true)
    }

    private func refreshCollectedMarks() {
        webView.evaluateJavaScript("window.JavDBCollect && window.JavDBCollect.reportVisible()")
    }

    private func applyCollected(ids: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ids), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.JavDBCollect && window.JavDBCollect.applyCollected(\(json))")
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
