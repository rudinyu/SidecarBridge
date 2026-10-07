import Foundation

/// Bounded status metadata describing the keyboard input source selected on
/// the Host. The versioned payload keeps the detail channel extensible without
/// making Viewer decode arbitrary-sized data.
struct HostInputSourceStatus: Equatable {
    static let prefix = "host-input-source:"

    private static let payloadVersion = 1
    private static let maximumPayloadByteCount = 5_120
    private static let maximumEncodedPayloadByteCount = ((maximumPayloadByteCount + 2) / 3) * 4

    let id: String
    let language: String
    let name: String

    init(id: String, language: String, name: String) {
        self.id = id
        self.language = language
        if name.isEmpty {
            self.name = id.utf8.count <= 256 ? id : "Input source"
        } else {
            self.name = name
        }
    }

    var detail: String {
        guard Self.hasValidFields(id: id, language: language, name: name),
              let data = try? JSONEncoder().encode(Payload(
                version: Self.payloadVersion,
                id: id,
                language: language,
                name: name
              )),
              data.count <= Self.maximumPayloadByteCount else {
            return Self.prefix
        }
        return Self.prefix + data.base64EncodedString()
    }

    static func parse(detail: String) -> Self? {
        guard detail.hasPrefix(prefix),
              detail.utf8.count <= prefix.utf8.count + maximumEncodedPayloadByteCount else { return nil }
        let encoded = String(detail.dropFirst(prefix.count))
        guard !encoded.isEmpty,
              encoded.utf8.count <= maximumEncodedPayloadByteCount,
              let data = Data(base64Encoded: encoded),
              data.count <= maximumPayloadByteCount,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == payloadVersion,
              hasValidFields(id: payload.id, language: payload.language, name: payload.name) else {
            return nil
        }
        return Self(id: payload.id, language: payload.language, name: payload.name)
    }

    private static func hasValidFields(id: String, language: String, name: String) -> Bool {
        return !id.isEmpty && id.utf8.count <= 512 &&
            !language.isEmpty && language.utf8.count <= 32 &&
            name.utf8.count <= 256
    }

    private struct Payload: Codable {
        let version: Int
        let id: String
        let language: String
        let name: String

        private static let expectedKeys: Set<String> = ["version", "id", "language", "name"]

        init(version: Int, id: String, language: String, name: String) {
            self.version = version
            self.id = id
            self.language = language
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard Set(container.allKeys.map(\.stringValue)) == Self.expectedKeys else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unsupported Host input-source payload fields.")
                )
            }
            version = try container.decode(Int.self, forKey: AnyCodingKey(stringValue: "version")!)
            id = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "id")!)
            language = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "language")!)
            name = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "name")!)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try container.encode(version, forKey: AnyCodingKey(stringValue: "version")!)
            try container.encode(id, forKey: AnyCodingKey(stringValue: "id")!)
            try container.encode(language, forKey: AnyCodingKey(stringValue: "language")!)
            try container.encode(name, forKey: AnyCodingKey(stringValue: "name")!)
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
