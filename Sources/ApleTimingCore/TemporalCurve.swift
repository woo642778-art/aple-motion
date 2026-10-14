import Foundation

// Scalar easing adapted from EffectCraft 549e9d825132986d6167c1432cd3328efcbb0278.
// Copyright (c) 2026 ArtCraft Team and the EffectCraft contributors. MIT; see THIRD_PARTY_NOTICES.md.

public enum Interpolation: String, Codable, CaseIterable, Sendable {
    case linear, bezier, hold
}

public struct Ease: Codable, Equatable, Sendable {
    public var speed: Double
    public var influence: Double
    public init(speed: Double = 0, influence: Double = 1.0/6) {
        self.speed = speed; self.influence = influence
    }
    public static let easy = Ease(speed: 0, influence: 1.0/3)
    internal func validate() throws {
        guard speed.isFinite, abs(speed) <= 1e100, influence.isFinite else { throw TimingError.invalidNumber }
        guard (0...1).contains(influence) else { throw TimingError.invalidInfluence }
    }
}

public struct ScalarKeyframe: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var time: Tick
    public var value: Double
    public var inInterpolation: Interpolation
    public var outInterpolation: Interpolation
    public var inEase: Ease
    public var outEase: Ease
    public var autoBezier: Bool

    public init(id: UUID = UUID(), time: Tick, value: Double,
                inInterpolation: Interpolation = .linear, outInterpolation: Interpolation = .linear,
                inEase: Ease = Ease(), outEase: Ease = Ease(), autoBezier: Bool = false) {
        self.id = id; self.time = time; self.value = value
        self.inInterpolation = inInterpolation; self.outInterpolation = outInterpolation
        self.inEase = inEase; self.outEase = outEase; self.autoBezier = autoBezier
    }
}

public struct ScalarCurve: Sendable {
    public let keys: [ScalarKeyframe]
    private let segments: [TemporalSegment]
    private let cumulative: [Double]

    public init(keys: [ScalarKeyframe]) throws {
        guard !keys.isEmpty else { throw TimingError.tooFewKeys }
        guard keys.count <= 100_000 else { throw TimingError.resourceLimit }
        guard Set(keys.map(\.id)).count == keys.count else { throw TimingError.invalidDocument }
        let sorted = keys.sorted { $0.time < $1.time }
        for key in sorted {
            guard key.value.isFinite, abs(key.value) <= 1e100 else { throw TimingError.invalidNumber }
            try key.inEase.validate(); try key.outEase.validate()
        }
        let span = sorted.last!.time.rawValue.subtractingReportingOverflow(sorted[0].time.rawValue)
        guard !span.overflow else { throw TimingError.overflow }
        var built: [TemporalSegment] = []
        var sums = [0.0]
        for i in 0..<(sorted.count-1) {
            let a = sorted[i], b = sorted[i+1]
            guard a.time < b.time else { throw TimingError.duplicateTime }
            let duration = a.time.seconds(to: b.time)
            let straight = Ease(speed: (b.value-a.value)/duration, influence: 1.0/3)
            let outgoing = a.outInterpolation == .linear ? straight : Self.effectiveEase(sorted, i, true)
            // Incoming Hold shapes the segment as a linear side. Outgoing Hold alone holds it.
            let incoming = b.inInterpolation != .bezier ? straight : Self.effectiveEase(sorted, i+1, false)
            let segment: TemporalSegment
            if a.outInterpolation == .hold {
                segment = TemporalSegment(duration: duration, x1: 1.0/3, x2: 2.0/3,
                                          y0: a.value, y1: a.value, y2: a.value, y3: a.value)
            } else {
                segment = TemporalSegment(duration: duration, x1: outgoing.influence, x2: 1-incoming.influence,
                    y0: a.value, y1: a.value+outgoing.speed*outgoing.influence*duration,
                    y2: b.value-incoming.speed*incoming.influence*duration, y3: b.value)
            }
            guard segment.isFinite else { throw TimingError.invalidNumber }
            built.append(segment)
            let next = sums.last! + segment.integral(progress: 1)
            guard next.isFinite else { throw TimingError.invalidNumber }
            sums.append(next)
        }
        self.keys = sorted; self.segments = built; self.cumulative = sums
    }

    public func value(at time: Tick) -> Double {
        if time <= keys[0].time || keys.count == 1 { return keys[0].value }
        if time >= keys.last!.time { return keys.last!.value }
        let i = segmentIndex(at: time)
        return segments[i].value(progress: keys[i].time.seconds(to: time) / segments[i].duration)
    }

    /// Same 1 ms central-difference convention as the pinned EffectCraft scalar velocity display.
    public func velocity(at time: Tick) -> Double {
        let h = Tick.ticksPerSecond / 1_000
        let lo = time.saturatedAdding(-h), hi = time.saturatedAdding(h)
        let dt = lo.seconds(to: hi)
        return dt > 0 ? (value(at: hi)-value(at: lo))/dt : 0
    }

    /// Signed area in value-seconds, including constant extrapolation outside the key range.
    public func integral(from start: Tick, to end: Tick) -> Double {
        primitive(at: end) - primitive(at: start)
    }

    public func sideEase(at index: Int, outgoing: Bool) -> Ease? {
        guard keys.indices.contains(index) else { return nil }
        let neighbor = outgoing ? index+1 : index-1
        guard keys.indices.contains(neighbor) else { return nil }
        let k = keys[index], n = keys[neighbor]
        let interpolation = outgoing ? k.outInterpolation : k.inInterpolation
        if interpolation == .hold || (!outgoing && n.outInterpolation == .hold) { return nil }
        if interpolation == .linear {
            return Ease(speed: (n.value-k.value)/k.time.seconds(to: n.time), influence: 1.0/3)
        }
        return Self.effectiveEase(keys, index, outgoing)
    }

    public static func normalizedEase(outSpeed: Double, outInfluence: Double,
                                      inSpeed: Double, inInfluence: Double, progress: Double) throws -> Double {
        try Ease(speed: outSpeed, influence: outInfluence).validate()
        try Ease(speed: inSpeed, influence: inInfluence).validate()
        guard progress.isFinite else { throw TimingError.invalidNumber }
        let u = solveU(x1: outInfluence, x2: 1-inInfluence, x: progress)
        return bez(0, outSpeed*outInfluence, 1-inSpeed*inInfluence, 1, u)
    }

    private static func effectiveEase(_ keys: [ScalarKeyframe], _ i: Int, _ outgoing: Bool) -> Ease {
        if keys[i].autoBezier && i > 0 && i+1 < keys.count {
            let dt = keys[i-1].time.seconds(to: keys[i+1].time)
            return Ease(speed: (keys[i+1].value-keys[i-1].value)/max(dt, 1e-12), influence: 1.0/6)
        }
        return outgoing ? keys[i].outEase : keys[i].inEase
    }
    private func segmentIndex(at time: Tick) -> Int {
        var lo = 0, hi = keys.count-1
        while lo+1 < hi {
            let mid = lo+(hi-lo)/2
            if keys[mid].time <= time { lo = mid } else { hi = mid }
        }
        return lo
    }
    private func primitive(at time: Tick) -> Double {
        if time <= keys[0].time || keys.count == 1 {
            return keys[0].time.seconds(to: time)*keys[0].value
        }
        if time >= keys.last!.time {
            return cumulative.last! + keys.last!.time.seconds(to: time)*keys.last!.value
        }
        let i = segmentIndex(at: time)
        return cumulative[i] + segments[i].integral(progress: keys[i].time.seconds(to: time)/segments[i].duration)
    }
}

private struct TemporalSegment: Sendable {
    let duration: Double
    let x1: Double, x2: Double
    let y0: Double, y1: Double, y2: Double, y3: Double
    var isFinite: Bool { [duration,x1,x2,y0,y1,y2,y3].allSatisfy(\.isFinite) }

    func value(progress: Double) -> Double { bez(y0,y1,y2,y3,solveU(x1:x1,x2:x2,x:progress)) }
    func integral(progress: Double) -> Double {
        let u = solveU(x1:x1,x2:x2,x:progress)
        // Integral y(u) * dx/du. Handles can cross; x(u) stays monotone for influences in 0...1.
        let y = [y0, 3*(y1-y0), 3*(y0-2*y1+y2), -y0+3*y1-3*y2+y3]
        let dx = [3*x1, 6*x2-12*x1, 3-9*x2+9*x1]
        var polynomial = Array(repeating: 0.0, count: 6)
        for i in 0..<4 { for j in 0..<3 { polynomial[i+j] += y[i]*dx[j] } }
        var power = u, area = 0.0
        for i in 0..<6 { area += polynomial[i]*power/Double(i+1); power *= u }
        return area*duration
    }
}

private func bez(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ u: Double) -> Double {
    let v = 1-u
    return v*v*v*p0 + 3*v*v*u*p1 + 3*v*u*u*p2 + u*u*u*p3
}
private func bezDerivative(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ u: Double) -> Double {
    let v = 1-u
    return 3*v*v*(p1-p0) + 6*v*u*(p2-p1) + 3*u*u*(p3-p2)
}
private func solveU(x1: Double, x2: Double, x: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    if x1 == 1 && x2 == 0 { return 0.5 + cbrt((x-0.5)*0.25) }
    var u = x
    for _ in 0..<8 {
        let f = bez(0,x1,x2,1,u)-x
        let d = bezDerivative(0,x1,x2,1,u)
        if abs(d) < 1e-12 { break }
        if abs(f/d) < 1e-12 { return u }
        let next = u-f/d
        if !(0...1).contains(next) { break }
        u = next
    }
    var lo = 0.0, hi = 1.0
    for _ in 0..<60 {
        let mid = (lo+hi)*0.5
        if bez(0,x1,x2,1,mid) < x { lo = mid } else { hi = mid }
    }
    return (lo+hi)*0.5
}

public enum SourceBoundaryPolicy: Sendable { case reject, clamp }

public struct SpeedRamp: Sendable {
    public let curve: ScalarCurve
    public let sourceOrigin: Double
    public var outputDuration: Tick { curve.keys.last!.time }

    public init(sourceOrigin: Double, keys: [ScalarKeyframe]) throws {
        guard sourceOrigin.isFinite, abs(sourceOrigin) <= 1e100 else { throw TimingError.invalidNumber }
        let curve = try ScalarCurve(keys: keys)
        guard curve.keys.count >= 2 else { throw TimingError.tooFewKeys }
        guard curve.keys[0].time == .zero, curve.keys.last!.time > .zero else { throw TimingError.invalidTime }
        self.curve = curve; self.sourceOrigin = sourceOrigin
    }
    public static func constant(outputDuration: Tick, speed: Double, sourceOrigin: Double = 0) throws -> SpeedRamp {
        guard outputDuration > .zero else { throw TimingError.invalidTime }
        return try SpeedRamp(sourceOrigin: sourceOrigin, keys: [
            ScalarKeyframe(time: .zero, value: speed), ScalarKeyframe(time: outputDuration, value: speed)
        ])
    }
    public func sourceTime(at outputTime: Tick) -> Double {
        sourceOrigin + curve.integral(from: .zero, to: outputTime)
    }
    /// The range endpoints must be valid source presentation timestamps, not an estimated last frame.
    public func sample(at outputTime: Tick, range: ClosedRange<Double>, policy: SourceBoundaryPolicy) throws -> Double {
        guard range.lowerBound.isFinite, range.upperBound.isFinite else { throw TimingError.invalidNumber }
        let value = sourceTime(at: outputTime)
        guard value.isFinite else { throw TimingError.invalidNumber }
        if range.contains(value) { return value }
        switch policy {
        case .reject: throw TimingError.outsideSourceRange
        case .clamp: return min(range.upperBound, max(range.lowerBound, value))
        }
    }
}
