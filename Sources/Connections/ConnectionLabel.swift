import Foundation

/// A user-defined label for connections: a name plus a color from the fixed
/// palette. Labels are defined once in Preferences and referenced by profiles
/// via `ConnectionProfile.labelID`, so a name/color change applies everywhere.
public struct ConnectionLabel: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var colorTag: ColorTag

    public init(id: UUID = UUID(), name: String, colorTag: ColorTag) {
        self.id = id
        self.name = name
        self.colorTag = colorTag
    }
}

// MARK: - Persistence (mirrors ProfileStore)

public struct LabelStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("dbosk/labels.json")
        }
    }

    public func load() throws -> [ConnectionLabel] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionLabel].self, from: data)
    }

    public func save(_ labels: [ConnectionLabel]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(labels)
        try data.write(to: fileURL, options: .atomic)
    }
}
