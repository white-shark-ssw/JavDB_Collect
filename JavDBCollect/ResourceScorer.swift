import Foundation

struct ScoredCandidate {
    let candidate: MagnetCandidate
    let score: Double
}

enum ResourceScorer {
    static let minimumSizeGB = 1.0

    private struct CandidateInfo {
        let candidate: MagnetCandidate
        let isSubtitle: Bool
        let isUltraClear: Bool
        let isHighDefinition: Bool
        let isSingleMP4: Bool
        let effectiveSize: Double
    }

    private static let subtitleSizeOverrideRatio = 2.5
    private static let subtitleSizeOverrideGapGB = 4.0
    private static let subtitleKeywords = ["字幕", "中字", "中文"]
    private static let folderKeywords = ["folder", "文件夹", "文件夾", "資料夾", "目录", "目錄"]

    static func best(from candidates: [MagnetCandidate]) -> ScoredCandidate? {
        let infos = candidates.compactMap(makeInfo)
        guard !infos.isEmpty else { return nil }

        let subtitles = infos.filter(\.isSubtitle)
        let ultraClear = infos.filter { !$0.isSubtitle && $0.isUltraClear }
        let highDefinition = infos.filter { !$0.isSubtitle && !$0.isUltraClear && $0.isHighDefinition }
        let normal = infos.filter { !$0.isSubtitle && !$0.isUltraClear && !$0.isHighDefinition }

        let bestSubtitle = bestWithin(subtitles)
        let bestUltraClear = bestWithin(ultraClear)

        if let subtitle = bestSubtitle, let ultra = bestUltraClear {
            let subtitleSize = max(subtitle.candidate.sizeGB, 0)
            let ultraSize = max(ultra.candidate.sizeGB, 0)
            let canOverrideSubtitle = subtitleSize > 0 && ultraSize >= subtitleSize * subtitleSizeOverrideRatio && ultraSize - subtitleSize >= subtitleSizeOverrideGapGB
            let selected = canOverrideSubtitle ? ultra : subtitle
            return ScoredCandidate(candidate: selected.candidate, score: selected.effectiveSize)
        }

        if let subtitle = bestSubtitle { return ScoredCandidate(candidate: subtitle.candidate, score: subtitle.effectiveSize) }
        if let ultra = bestUltraClear { return ScoredCandidate(candidate: ultra.candidate, score: ultra.effectiveSize) }
        if let hd = bestWithin(highDefinition) { return ScoredCandidate(candidate: hd.candidate, score: hd.effectiveSize) }
        if let fallback = bestWithin(normal) { return ScoredCandidate(candidate: fallback.candidate, score: fallback.effectiveSize) }
        return nil
    }

    private static func makeInfo(_ candidate: MagnetCandidate) -> CandidateInfo? {
        guard candidate.sizeGB >= minimumSizeGB else { return nil }

        let combined = ([candidate.name, candidate.meta] + candidate.tags).joined(separator: " ").lowercased()
        if isISO(combined) { return nil }

        let subtitle = subtitleKeywords.contains(where: { combined.contains($0) }) || containsToken(combined, tokens: ["chs", "cht", "sub", "subtitle"]) || hasDashCMarker(candidate.name)
        let ultraClear = combined.contains("超清") || containsToken(combined, tokens: ["4k", "2160p", "uhd"])
        let highDefinition = combined.contains("高清") || containsToken(combined, tokens: ["1080p", "fhd", "hd"])
        let singleMP4 = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(".mp4")

        var effectiveSize = max(candidate.sizeGB, 0)
        if singleMP4 { effectiveSize -= 0.75 }
        if candidate.fileCount > 1 { effectiveSize += 0.5 + min(Double(candidate.fileCount), 10) * 0.03 }
        if folderKeywords.contains(where: { combined.contains($0) }) { effectiveSize += 0.3 }
        if ultraClear { effectiveSize += 0.35 }
        else if highDefinition { effectiveSize += 0.15 }

        return CandidateInfo(candidate: candidate, isSubtitle: subtitle, isUltraClear: ultraClear, isHighDefinition: highDefinition, isSingleMP4: singleMP4, effectiveSize: effectiveSize)
    }

    private static func bestWithin(_ infos: [CandidateInfo]) -> CandidateInfo? {
        infos.max { lhs, rhs in
            if lhs.effectiveSize != rhs.effectiveSize { return lhs.effectiveSize < rhs.effectiveSize }
            if lhs.isSingleMP4 != rhs.isSingleMP4 { return lhs.isSingleMP4 && !rhs.isSingleMP4 }
            if lhs.candidate.fileCount != rhs.candidate.fileCount { return lhs.candidate.fileCount < rhs.candidate.fileCount }
            return lhs.candidate.sizeGB < rhs.candidate.sizeGB
        }
    }

    private static func isISO(_ text: String) -> Bool {
        if text.contains(".iso") { return true }
        return text.range(of: #"(?i)(^|[\s._-])iso($|[\s._-])"#, options: .regularExpression) != nil
    }

    private static func hasDashCMarker(_ text: String) -> Bool {
        text.range(of: #"(?i)-c(?=$|[._\-\s])"#, options: .regularExpression) != nil
    }

    private static func containsToken(_ text: String, tokens: [String]) -> Bool {
        for token in tokens {
            let escaped = NSRegularExpression.escapedPattern(for: token)
            if text.range(of: "(?i)(^|[^a-z0-9])\(escaped)(?=$|[^a-z0-9])", options: .regularExpression) != nil { return true }
        }
        return false
    }
}
