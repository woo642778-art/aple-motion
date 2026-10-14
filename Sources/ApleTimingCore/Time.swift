import Foundation

public enum TimingError: Error, Equatable, Sendable, LocalizedError {
    case invalidNumber, invalidTime, duplicateTime, tooFewKeys, invalidInfluence
    case overflow, unsupportedFrameRate, outsideSourceRange, invalidSchema, invalidIndex
    case invalidDocument, resourceLimit

    public var errorDescription: String? {
        switch self {
        case .invalidNumber: return "A timing value is not a supported finite number."
        case .invalidTime: return "The time or duration is invalid."
        case .duplicateTime: return "Two keyframes cannot share the same time."
        case .tooFewKeys: return "The curve does not contain enough keyframes."
        case .invalidInfluence: return "Influence must be between zero and one."
        case .overflow: return "The requested time exceeds the supported range."
        case .unsupportedFrameRate: return "This frame rate cannot be represented exactly in the tick timebase."
        case .outsideSourceRange: return "The remap leaves the valid source presentation-time range."
        case .invalidSchema: return "This timing document version is not supported."
        case .invalidIndex: return "The selected frame or keyframe does not exist."
        case .invalidDocument: return "The timing document is inconsistent."
        case .resourceLimit: return "The requested operation exceeds the configured resource limit."
        }
    }
}

public struct Tick: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public static let ticksPerSecond: Int64 = 254_016_000_000
    public static let zero = Tick(rawValue: 0)
    public let rawValue: Int64

    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(seconds: Double) throws {
        guard seconds.isFinite else { throw TimingError.invalidNumber }
        let scaled = (seconds * Double(Self.ticksPerSecond)).rounded()
        // Double(Int64.max) rounds up to 2^63 and must not be converted to Int64.
        guard scaled.isFinite, scaled >= Double(Int64.min), scaled < Double(Int64.max) else {
            throw TimingError.overflow
        }
        self.rawValue = Int64(scaled)
    }
    public var seconds: Double { Double(rawValue) / Double(Self.ticksPerSecond) }
    public static func < (lhs: Tick, rhs: Tick) -> Bool { lhs.rawValue < rhs.rawValue }

    public func adding(_ delta: Int64) throws -> Tick {
        let result = rawValue.addingReportingOverflow(delta)
        guard !result.overflow else { throw TimingError.overflow }
        return Tick(rawValue: result.partialValue)
    }
    internal func saturatedAdding(_ delta: Int64) -> Tick {
        let result = rawValue.addingReportingOverflow(delta)
        return Tick(rawValue: result.overflow ? (delta < 0 ? Int64.min : Int64.max) : result.partialValue)
    }
    internal func seconds(to other: Tick) -> Double {
        let difference = other.rawValue.subtractingReportingOverflow(rawValue)
        if !difference.overflow { return Double(difference.partialValue) / Double(Self.ticksPerSecond) }
        return other.seconds - seconds
    }
}

public struct FrameRate: Equatable, Sendable {
    public let numerator: Int64
    public let denominator: Int64
    public let ticksPerFrame: Int64

    public init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
        guard numerator > 0, denominator > 0 else { throw TimingError.unsupportedFrameRate }
        var a = numerator, b = denominator
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        let n = numerator / a, d = denominator / a
        guard Tick.ticksPerSecond % n == 0 else { throw TimingError.unsupportedFrameRate }
        let product = (Tick.ticksPerSecond / n).multipliedReportingOverflow(by: d)
        guard !product.overflow, product.partialValue > 0 else { throw TimingError.overflow }
        self.numerator = n
        self.denominator = d
        self.ticksPerFrame = product.partialValue
    }
    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }
    public func time(forFrame frame: Int64) throws -> Tick {
        let product = frame.multipliedReportingOverflow(by: ticksPerFrame)
        guard !product.overflow else { throw TimingError.overflow }
        return Tick(rawValue: product.partialValue)
    }
}

/// Lazy frame-index mapping. The duration is an exclusive end, never an extra frame PTS.
public struct FrameSchedule: Sendable {
    public let duration: Tick
    public let rate: FrameRate
    public let count: Int64

    public init(duration: Tick, rate: FrameRate, maxFrames: Int64 = 10_000_000) throws {
        guard duration.rawValue >= 0 else { throw TimingError.invalidTime }
        guard maxFrames >= 0 else { throw TimingError.resourceLimit }
        let quotient = duration.rawValue / rate.ticksPerFrame
        let count = quotient + (duration.rawValue % rate.ticksPerFrame == 0 ? 0 : 1)
        guard count <= maxFrames else { throw TimingError.resourceLimit }
        self.duration = duration
        self.rate = rate
        self.count = count
    }
    public func time(at index: Int64) throws -> Tick {
        guard index >= 0, index < count else { throw TimingError.invalidIndex }
        return try rate.time(forFrame: index)
    }
}
