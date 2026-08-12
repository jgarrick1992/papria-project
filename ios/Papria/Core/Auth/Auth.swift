import Foundation

struct LoginRequest: Encodable {
    let username: String
    let password: String
}

struct LoginResponse: Decodable, Sendable {
    let accessToken: String

    private enum CodingKeys: String, CodingKey { case accessToken }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let token = try values.decode(String.self, forKey: .accessToken)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .accessToken, in: values, debugDescription: "accessToken must not be empty")
        }
        accessToken = token
    }
}

struct RefreshResponse: Decodable {
    let accessToken: String

    private enum CodingKeys: String, CodingKey { case accessToken }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let token = try values.decode(String.self, forKey: .accessToken)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .accessToken, in: values, debugDescription: "accessToken must not be empty")
        }
        accessToken = token
    }
}
