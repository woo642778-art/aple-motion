import Foundation

public enum TimingMode: String, Codable, Sendable { case property, speedRamp }

/// A typed timing payload for the host adapter. It is not a replacement for an Aple Motion project.
public struct TimingDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var mode: TimingMode
    public var keys: [ScalarKeyframe]
    public var sourceOrigin: Double
    public static let maximumEncodedBytes = 16 * 1024 * 1024

    public init(mode: TimingMode, keys: [ScalarKeyframe], sourceOrigin: Double = 0) throws {
        self.schemaVersion = 1; self.mode = mode
        self.keys = keys.sorted { $0.time < $1.time }; self.sourceOrigin = sourceOrigin
        try validate()
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw TimingError.invalidSchema }
        guard sourceOrigin.isFinite, abs(sourceOrigin) <= 1e100 else { throw TimingError.invalidNumber }
        let checked = try ScalarCurve(keys: keys)
        guard checked.keys == keys else { throw TimingError.invalidDocument }
        if mode == .speedRamp { _ = try SpeedRamp(sourceOrigin: sourceOrigin, keys: keys) }
    }
    public func curve() throws -> ScalarCurve { try ScalarCurve(keys: keys) }
    public func ramp() throws -> SpeedRamp {
        guard mode == .speedRamp else { throw TimingError.invalidDocument }
        return try SpeedRamp(sourceOrigin: sourceOrigin, keys: keys)
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw TimingError.resourceLimit }
        return data
    }
    public static func decode(_ data: Data) throws -> TimingDocument {
        guard data.count <= maximumEncodedBytes else { throw TimingError.resourceLimit }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func save(to url: URL) throws {
        guard url.isFileURL else { throw TimingError.invalidDocument }
        try encoded().write(to: url, options: .atomic)
    }
    public static func load(from url: URL) throws -> TimingDocument {
        guard url.isFileURL else { throw TimingError.invalidDocument }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= maximumEncodedBytes else { throw TimingError.resourceLimit }
        return try decode(Data(contentsOf: url))
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, mode, keys, sourceOrigin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw TimingError.invalidSchema }
        mode = try c.decode(TimingMode.self, forKey: .mode)
        keys = try c.decode([ScalarKeyframe].self, forKey: .keys)
        sourceOrigin = try c.decode(Double.self, forKey: .sourceOrigin)
        try validate()
    }
}

public struct DocumentHistory: Sendable {
    public private(set) var current: TimingDocument
    private var past: [TimingDocument] = []
    private var future: [TimingDocument] = []
    private let limit: Int
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public init(initial: TimingDocument, limit: Int = 100) throws {
        guard limit > 0, limit <= 10_000 else { throw TimingError.resourceLimit }
        try initial.validate()
        self.current = initial; self.limit = limit
    }
    public mutating func commit(_ document: TimingDocument) throws {
        try document.validate()
        guard document != current else { return }
        past.append(current)
        if past.count > limit { past.removeFirst(past.count-limit) }
        current = document; future.removeAll(keepingCapacity: true)
    }
    @discardableResult public mutating func undo() -> TimingDocument? {
        guard let previous = past.popLast() else { return nil }
        future.append(current); current = previous; return previous
    }
    @discardableResult public mutating func redo() -> TimingDocument? {
        guard let next = future.popLast() else { return nil }
        past.append(current); current = next; return next
    }
}
