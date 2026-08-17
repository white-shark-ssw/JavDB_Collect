import Foundation

struct ScoredCandidate {
    let candidate: MagnetCandidate
    let score: Double
}

enum ResourceScorer {
    private static let blockedKeywords = [".iso", " iso", "iso ", "bdmv", "blu-ray", "blu ray", "原盘", "原盤"]
    private static let subtitleKeywords = ["字幕", "中字", "中文", "chs", "cht", "sub", "subtitle"]
    private static let folderKeywords = ["folder", "文件夹", "文件夾", "資料夾", "目录", "目錄"]

    static func best(from candidates: [MagnetCandidate]) -> ScoredCandidate? {
        candidates.compactMap(score).max { $0.score < $1.score }
    }

    private static func score(_ candidate: MagnetCandidate) -> ScoredCandidate? {
        let combined = ([candidate.name, candidate.meta] + candidate.tags).joined(separator: " ").lowercased()
        if blockedKeywords.contains(where: { combined.contains($0) }) { return nil }

        var value = 0.0
        if subtitleKeywords.contains(where: { combined.contains($0) }) { value += 1000 }
        if folderKeywords.contains(where: { combined.contains($0) }) { value += 400 }
        if candidate.fileCount > 1 { value += 250 + min(Double(candidate.fileCount), 20) }
        if combined.contains("高清") || combined.contains("hd") { value += 20 }
        value += max(candidate.sizeGB, 0) * 10
        return ScoredCandidate(candidate: candidate, score: value)
    }
}
