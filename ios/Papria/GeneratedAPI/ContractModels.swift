import Foundation

struct FileProgressPayload: Codable, Equatable, Sendable {
    let percentage: Double
    let cfi: String?
    let pageNumber: Int?
    let positionSeconds: Double?
    let updatedAt: String?
    let dirty: Bool
    let koboLocationSource: String?
    let koboLocationType: String?
    let koboLocationValue: String?
    let koboContentSourceProgressPercent: Double?
    let koreaderProgress: String?

    init(percentage: Double, cfi: String? = nil, pageNumber: Int? = nil, positionSeconds: Double? = nil, updatedAt: String? = nil, dirty: Bool = false, koboLocationSource: String? = nil, koboLocationType: String? = nil, koboLocationValue: String? = nil, koboContentSourceProgressPercent: Double? = nil, koreaderProgress: String? = nil) {
        self.percentage = percentage
        self.cfi = cfi
        self.pageNumber = pageNumber
        self.positionSeconds = positionSeconds
        self.updatedAt = updatedAt
        self.dirty = dirty
        self.koboLocationSource = koboLocationSource
        self.koboLocationType = koboLocationType
        self.koboLocationValue = koboLocationValue
        self.koboContentSourceProgressPercent = koboContentSourceProgressPercent
        self.koreaderProgress = koreaderProgress
    }
}

struct AudioProgressPayload: Codable, Equatable, Sendable {
    let percentage: Double
    let currentFileId: Int64
    let positionSeconds: Double
    let updatedAt: String?
    let dirty: Bool

    init(percentage: Double, currentFileId: Int64, positionSeconds: Double, updatedAt: String? = nil, dirty: Bool = false) {
        self.percentage = percentage
        self.currentFileId = currentFileId
        self.positionSeconds = positionSeconds
        self.updatedAt = updatedAt
        self.dirty = dirty
    }

    private enum CodingKeys: String, CodingKey { case percentage, currentFileId, positionSeconds, updatedAt, dirty }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        percentage = try values.decode(Double.self, forKey: .percentage)
        currentFileId = try values.decode(Int64.self, forKey: .currentFileId)
        positionSeconds = try values.decode(Double.self, forKey: .positionSeconds)
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        dirty = try values.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
    }
}

struct BookQueryRequest: Encodable, Sendable {
    let sort: [BookSort]
    let pagination: Pagination
    let collapseSeries: Bool
    let q: String?
}

struct BookSort: Encodable, Sendable {
    let field: String
    let dir: String
}

struct Pagination: Encodable, Sendable {
    let page: Int
    let size: Int
}
