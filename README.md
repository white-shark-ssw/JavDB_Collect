# JavDB Collect

JavDB Collect 是一个面向 iOS 的轻量 JavDB 增强采集工具，目标是在 App 内浏览 JavDB、从影片详情页选择并保存磁力链接、持久化本次采集与历史状态，并批量复制磁链到 115 云下载。

## 当前目标

- iOS 16.0+，重点测试 iOS 17.0
- TrollStore 安装 unsigned IPA
- UIKit + WKWebView
- SQLite 本地持久化
- JavDB 列表页/详情页显示“已采集”标记
- 本次采集持久保存，App 退出后不丢失
- 一键复制本次全部磁链，每行一条
- “清理本次”仅把本次记录转为历史，不删除采集状态

## 暂不包含

- 115 API 直推
- Emby API
- 云同步
- JavDB 收藏同步

详细设计见 `docs/design.md`。
