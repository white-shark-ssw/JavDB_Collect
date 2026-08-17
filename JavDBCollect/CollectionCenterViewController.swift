import UIKit

final class CollectionCenterViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
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
        guard segmentedControl.selectedSegmentIndex == 0 else { toolbarItems = []; return }
        let copy = UIBarButtonItem(title: "复制全部", style: .done, target: self, action: #selector(copyAll))
        let flexible = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let clear = UIBarButtonItem(title: "清理本次", style: .plain, target: self, action: #selector(clearCurrent))
        toolbarItems = [copy, flexible, clear]
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
        guard currentStatus == 0 else { return nil }
        let record = records[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "撤销") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.store.deleteCurrent(id: record.id)
            self.reloadData()
            self.onDatabaseChanged?()
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak alert] in alert?.dismiss(animated: true) }
    }
}
