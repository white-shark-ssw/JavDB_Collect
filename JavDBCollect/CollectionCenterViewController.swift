import UIKit
import UniformTypeIdentifiers

final class CollectionCenterViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private let store: CollectionStore
    private let segmentedControl = UISegmentedControl(items: ["本次采集", "历史"])
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var records: [CollectRecord] = []
    var onDatabaseChanged: (() -> Void)?

    init(store: CollectionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "采集中心"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))

        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        navigationItem.titleView = segmentedControl

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        navigationController?.setToolbarHidden(false, animated: false)
        reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateToolbar()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func segmentChanged() {
        reloadData()
        updateToolbar()
    }

    private var currentStatus: Int { segmentedControl.selectedSegmentIndex == 0 ? 0 : 1 }

    private func reloadData() {
        records = store.fetch(status: currentStatus)
        tableView.reloadData()
    }

    private func updateToolbar() {
        let flexible = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        if segmentedControl.selectedSegmentIndex == 0 {
            let copy = UIBarButtonItem(title: "复制全部", style: .done, target: self, action: #selector(copyAll))
            let clear = UIBarButtonItem(title: "清理本次", style: .plain, target: self, action: #selector(clearCurrent))
            toolbarItems = [copy, flexible, clear]
        } else {
            let importButton = UIBarButtonItem(title: "导入数据库", style: .plain, target: self, action: #selector(importDatabase))
            let exportButton = UIBarButtonItem(title: "导出数据库", style: .done, target: self, action: #selector(exportDatabase))
            toolbarItems = [importButton, flexible, exportButton]
        }
    }

    @objc private func copyAll() {
        let magnets = store.currentMagnets()
        guard !magnets.isEmpty else { showMessage("本次采集为空"); return }
        UIPasteboard.general.string = magnets.joined(separator: "\n")
        showMessage("已复制 \(magnets.count) 条磁链，每行一条")
    }

    @objc private func clearCurrent() {
        let count = store.fetch(status: 0).count
        guard count > 0 else { showMessage("本次采集为空"); return }
        let alert = UIAlertController(title: "清理本次采集", message: "\(count) 条记录会转入历史，已采集状态会继续保留。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认清理", style: .default) { [weak self] _ in
            guard let self else { return }
            self.store.moveCurrentToHistory()
            self.reloadData()
            self.onDatabaseChanged?()
        })
        present(alert, animated: true)
    }

    @objc private func exportDatabase() {
        guard let url = store.makeDatabaseExport() else { showMessage("数据库导出失败"); return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        present(picker, animated: true)
    }

    @objc private func importDatabase() {
        let sqliteType = UTType(filenameExtension: "sqlite3") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [sqliteType, .data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let alert = UIAlertController(title: "导入数据库", message: "导入会覆盖当前 App 内的本次采集和历史记录。确定继续吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "覆盖导入", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            let success = self.store.importDatabase(from: url)
            if accessing { url.stopAccessingSecurityScopedResource() }
            guard success else { self.showMessage("数据库格式不兼容或导入失败"); return }
            self.reloadData()
            self.onDatabaseChanged?()
            self.showMessage("数据库导入成功")
        })
        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { records.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let record = records[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = record.code
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cell.detailTextLabel?.text = record.title
        cell.detailTextLabel?.numberOfLines = 2
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let status = currentStatus
        let record = records[indexPath.row]
        let title = status == 0 ? "撤销" : "删除"
        let delete = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.store.delete(id: record.id, status: status)
            self.reloadData()
            self.onDatabaseChanged?()
            completion(true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak alert] in alert?.dismiss(animated: true) }
    }
}
