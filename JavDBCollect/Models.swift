import Foundation

struct CollectRecord {
    let id: Int64
    let javdbID: String
    let code: String
    let title: String
    let magnet: String
    let status: Int
    let createdAt: TimeInterval
    let updatedAt: TimeInterval
}

struct MagnetCandidate: Decodable {
    let magnet: String
    let name: String
    let meta: String
    let tags: [String]
    let sizeGB: Double
    let fileCount: Int
}

struct MoviePayload: Decodable {
    let javdbId: String
    let code: String
    let title: String
    let coverUrl: String
    let candidates: [MagnetCandidate]
}

struct ParseEnvelope: Decodable {
    let error: String?
    let javdbId: String?
    let code: String?
    let title: String?
    let coverUrl: String?
    let candidates: [MagnetCandidate]?

    var moviePayload: MoviePayload? {
        guard error == nil,
              let javdbId,
              let code,
              let title,
              let coverUrl,
              let candidates else { return nil }
        return MoviePayload(javdbId: javdbId, code: code, title: title, coverUrl: coverUrl, candidates: candidates)
    }
}
