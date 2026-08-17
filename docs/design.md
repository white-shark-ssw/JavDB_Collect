# JavDB Collect 设计文档

## 1. 项目目标

JavDB Collect 是一个自用 iOS JavDB 增强浏览器。核心目标是把“选片 → 找磁链 → 复制 → 切换到 115 → 粘贴”的重复操作压缩为：

1. 在 App 内浏览 JavDB。
2. 进入影片详情页后点一次“采集”。
3. App 按规则从页面资源中自动选择一个磁链并持久保存。
4. 在“本次采集”中一键复制全部磁链，每行一条。
5. 用户到 115 云下载界面一次性粘贴批量离线。
6. “清理本次”只把本次采集转入历史，不删除采集状态。

第一版不直接调用 115 API，也不接入 Emby。

## 2. 平台与安装

- UIKit
- WKWebView
- Swift 5
- Deployment Target: iOS 15.0
- 重点测试设备：iOS 17.0
- GitHub Actions 使用 macOS runner 构建 unsigned IPA
- 目标安装方式：TrollStore

## 3. 页面解析依据

目前保存的 JavDB 详情页可以直接从 DOM 读取磁链资源，核心结构包含：

- `#magnets-content`
- `.item`
- `a[href^="magnet:"]`
- `.name`
- `.meta`
- `.tag`

资源元信息中可获得大小与文件数量。页面列表/搜索结果中的影片链接可通过 `/v/{javdb_id}` 提取稳定的 JavDB ID。

解析逻辑集中放在 `Resources/javdb_collector.js`，避免 Swift 业务代码依赖具体 DOM。

## 4. JS / Native 职责边界

### JavaScript

- 解析当前详情页。
- 提取影片 JavDB ID、番号、标题、封面 URL。
- 提取全部磁链候选及其名称、大小、文件数量、标签。
- 扫描列表页/动态加载区域中的影片链接。
- 通过 MutationObserver 监听页面变化。
- 在列表封面及详情页插入“已采集”标记。
- 通过 WKScriptMessageHandler 把当前页面可见 JavDB ID 发送给 Swift。

### Swift

- WKWebView 生命周期与 Cookie 持久化。
- SQLite 数据库。
- 候选资源评分与最终选择。
- 本次采集/历史 UI。
- 剪贴板批量复制。
- 根据数据库状态把“已采集 ID”返回 JS。

## 5. 数据模型

第一版使用一张表即可，不引入下载状态机。

```sql
CREATE TABLE collections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    javdb_id TEXT NOT NULL UNIQUE,
    code TEXT NOT NULL,
    title TEXT NOT NULL,
    magnet TEXT NOT NULL,
    status INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
```

`status`：

- `0`: 本次采集
- `1`: 历史采集

“已采集”的定义：数据库中存在该 `javdb_id`，无论 status 为 0 还是 1。

因此：

- App 中途退出，本次采集不会丢失。
- 清理本次只是 `status: 0 -> 1`。
- 本次采集与历史记录都会让 JavDB 列表封面显示“已采集”。

## 6. 资源评分规则

第一版自动选择最高分磁链。

### 硬排除

候选名称、标签或元信息包含以下关键词时直接排除：

- `ISO`
- `.iso`
- `BDMV`
- `Blu-ray` / `Blu ray`
- `原盘` / `原盤`

### 优先级

1. 字幕优先：`字幕`、`中字`、`中文`、`CHS`、`CHT`、`SUB`、`subtitle`。
2. 明显目录/多文件结构优先：`folder`、`文件夹`、`資料夾`、`目录`、`目錄`，以及文件数量 > 1。
3. 大小更大的资源优先。
4. `高清` 等标签只做轻量加分，不覆盖字幕与结构优先级。

评分逻辑放在 Swift `ResourceScorer`，后续调整规则无需修改页面解析脚本。

## 7. UI

### 主浏览页

- 全屏 WKWebView。
- 右下角一个原生悬浮按钮。
- 点击展开菜单：
  - 采集当前
  - 采集中心
- 支持 WKWebView 左右滑动返回/前进。

### 本次采集

- 持久化记录列表。
- 一键复制全部磁链：剪贴板格式严格为每行一条磁链。
- 一键清理本次：把全部 status=0 更新为 status=1。
- 支持删除单条“本次采集”以撤销误操作。

### 历史

- 查看已清理的历史采集记录。
- 第一版不做下载状态与 Emby 状态。

## 8. 已采集标记

JS 扫描当前页面所有 `/v/{javdb_id}` 链接，把可见 ID 发送给 Swift。

Swift 查询 SQLite 后只返回已存在的 ID，JS 负责：

- 列表页：在封面卡片右上角显示“✓ 已采集”。
- 详情页：显示“✓ 已采集”。

MutationObserver 用于处理 JavDB 翻页、懒加载或动态 DOM 更新。

## 9. 第一版不做

- 115 API / Cookie 直推
- Emby API
- JavDB 收藏同步
- 云同步
- 下载完成状态
- 自动文件整理
- 多账号

## 10. GitHub Actions

仓库内 workflow：`.github/workflows/build-ipa.yml`

构建步骤：

1. macOS runner checkout。
2. 安装 XcodeGen。
3. 根据 `project.yml` 生成 Xcode project。
4. `xcodebuild` 以 `CODE_SIGNING_ALLOWED=NO` 构建 Release iphoneos App。
5. 打包 `Payload/JavDBCollect.app` 为 `JavDBCollect.ipa`。
6. 上传为 GitHub Actions Artifact，供 TrollStore 测试安装。
