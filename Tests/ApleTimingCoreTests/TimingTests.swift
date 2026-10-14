import XCTest
@testable import ApleTimingCore

final class TimingTests: XCTestCase {
    private func t(_ s: Double) throws -> Tick { try Tick(seconds: s) }
    private func key(_ s: Double, _ v: Double, incoming: Interpolation = .linear,
                     outgoing: Interpolation = .linear, ie: Ease = Ease(),
                     oe: Ease = Ease(), auto: Bool = false) throws -> ScalarKeyframe {
        ScalarKeyframe(time: try t(s), value: v, inInterpolation: incoming,
                      outInterpolation: outgoing, inEase: ie, outEase: oe, autoBezier: auto)
    }

    func testTickRoundTrip() throws {
        let tick = try t(1)
        XCTAssertEqual(tick.rawValue, 254_016_000_000)
        XCTAssertEqual(tick.seconds, 1)
        XCTAssertEqual(try t(-0.5).seconds, -0.5)
    }
    func testTickRejectsNonFiniteAndOverflow() {
        XCTAssertThrowsError(try t(.nan))
        XCTAssertThrowsError(try t(.infinity))
        XCTAssertThrowsError(try t(1e12))
    }
    func testLinearAndEndpointClamping() throws {
        let c = try ScalarCurve(keys: [key(0, 10), key(2, 30)])
        XCTAssertEqual(c.value(at: try t(0.5)), 15, accuracy: 1e-10)
        XCTAssertEqual(c.value(at: try t(-1)), 10)
        XCTAssertEqual(c.value(at: try t(3)), 30)
    }
    func testHoldIsRightContinuousAtNextKey() throws {
        let c = try ScalarCurve(keys: [key(0, 2, outgoing: .hold), key(1, 9)])
        XCTAssertEqual(c.value(at: try t(0.999)), 2)
        XCTAssertEqual(c.value(at: try t(1)), 9)
    }
    func testIncomingHoldBehavesLikeLinearSide() throws {
        let c = try ScalarCurve(keys: [
            key(0, 0, outgoing: .bezier, oe: .easy), key(1, 1, incoming: .hold)
        ])
        XCTAssertEqual(c.value(at: try t(0.5)), 0.375, accuracy: 1e-10)
    }
    func testEasyEaseValuesAndIntegral() throws {
        let c = try ScalarCurve(keys: [
            key(0, 0, outgoing: .bezier, oe: .easy),
            key(1, 1, incoming: .bezier, ie: .easy)
        ])
        XCTAssertEqual(c.value(at: try t(0.25)), 0.15625, accuracy: 1e-10)
        XCTAssertEqual(c.value(at: try t(0.5)), 0.5, accuracy: 1e-10)
        XCTAssertEqual(c.integral(from: .zero, to: try t(1)), 0.5, accuracy: 1e-10)
    }
    func testEqualValuesCanStillOvershoot() throws {
        let c = try ScalarCurve(keys: [
            key(0, 1, outgoing: .bezier, oe: Ease(speed: 2, influence: 1.0/3)),
            key(1, 1, incoming: .bezier, ie: Ease(speed: -2, influence: 1.0/3))
        ])
        XCTAssertEqual(c.value(at: try t(0.5)), 1.5, accuracy: 1e-10)
        XCTAssertEqual(c.integral(from: .zero, to: try t(1)), 4.0/3, accuracy: 1e-10)
    }
    func testFullInfluenceMidpointAndNearbyValues() throws {
        let c = try ScalarCurve(keys: [
            key(0, 0, outgoing: .bezier, oe: Ease(speed: 0, influence: 1)),
            key(1, 1, incoming: .bezier, ie: Ease(speed: 0, influence: 1))
        ])
        XCTAssertEqual(c.value(at: try t(0.5)), 0.5, accuracy: 1e-12)
        XCTAssertLessThan(c.value(at: try t(0.499999)), 0.5)
        XCTAssertGreaterThan(c.value(at: try t(0.500001)), 0.5)
        XCTAssertEqual(c.integral(from: .zero, to: try t(1)), 0.5, accuracy: 1e-10)
    }
    func testCrossedInfluencesAreNotRescaled() throws {
        let x = 0.31
        let actual = try ScalarCurve.normalizedEase(outSpeed: 0, outInfluence: 0.9,
                            inSpeed: 0, inInfluence: 0.8, progress: x)
        var lo = 0.0, hi = 1.0
        for _ in 0..<80 {
            let u = (lo + hi) / 2, v = 1-u
            let tx = 3*v*v*u*0.9 + 3*v*u*u*0.2 + u*u*u
            if tx < x { lo = u } else { hi = u }
        }
        let u = (lo+hi)/2
        XCTAssertEqual(actual, 3*(1-u)*u*u + u*u*u, accuracy: 1e-10)
    }
    func testAutoBezierUsesNeighborSlope() throws {
        let c = try ScalarCurve(keys: [
            key(0, 0), key(1, 1, incoming: .bezier, outgoing: .bezier, auto: true), key(3, 6)
        ])
        XCTAssertEqual(try XCTUnwrap(c.sideEase(at: 1, outgoing: true)).speed, 2)
        XCTAssertEqual(try XCTUnwrap(c.sideEase(at: 1, outgoing: false)).influence, 1.0/6)
    }
    func testVelocityUsesCentralDifferenceLikeReference() throws {
        let c = try ScalarCurve(keys: [key(0, 0), key(2, 20)])
        XCTAssertEqual(c.velocity(at: try t(1)), 10, accuracy: 1e-8)
        XCTAssertEqual(c.velocity(at: .zero), 5, accuracy: 1e-8)
    }
    func testIntegralExtrapolationAndReversedLimits() throws {
        let c = try ScalarCurve(keys: [key(0, 1), key(1, 3)])
        XCTAssertEqual(c.integral(from: try t(-1), to: try t(2)), 6, accuracy: 1e-10)
        XCTAssertEqual(c.integral(from: try t(2), to: try t(-1)), -6, accuracy: 1e-10)
    }
    func testSingleKeyIsConstant() throws {
        let c = try ScalarCurve(keys: [key(1, 7)])
        XCTAssertEqual(c.value(at: .zero), 7)
        XCTAssertEqual(c.integral(from: .zero, to: try t(3)), 21, accuracy: 1e-10)
    }
    func testRejectsDuplicateTimesAndInvalidEases() throws {
        XCTAssertThrowsError(try ScalarCurve(keys: [key(0, 0), key(0, 1)]))
        XCTAssertThrowsError(try ScalarCurve(keys: [key(0, .nan)]))
        XCTAssertThrowsError(try ScalarCurve(keys: [key(0, 1, oe: Ease(speed: .infinity, influence: 0.5))]))
        XCTAssertThrowsError(try ScalarCurve(keys: [key(0, 1, ie: Ease(speed: 1, influence: 1.1))]))
        XCTAssertThrowsError(try ScalarCurve(keys: []))
    }
    func testConstantSlowFastReverseAndFreeze() throws {
        for speed in [0.0, 0.25, 0.5, 1, 2, -1, -2] {
            let ramp = try SpeedRamp.constant(outputDuration: t(4), speed: speed, sourceOrigin: 10)
            XCTAssertEqual(ramp.sourceTime(at: try t(3)), 10 + speed*3, accuracy: 1e-10)
        }
    }
    func testSpeedRampUsesIntegralNotInstantaneousSpeedProduct() throws {
        let ramp = try SpeedRamp(sourceOrigin: 0, keys: [key(0, 0), key(2, 2)])
        XCTAssertEqual(ramp.sourceTime(at: try t(1)), 0.5, accuracy: 1e-10)
        XCTAssertEqual(ramp.sourceTime(at: try t(2)), 2, accuracy: 1e-10)
    }
    func testBezierTimeIntegralAgainstQuadrature() throws {
        let keys = try [key(0, 1, outgoing: .bezier, oe: Ease(speed: 1, influence: 0.8)),
                        key(2, 3, incoming: .bezier, ie: Ease(speed: -2, influence: 0.6))]
        let c = try ScalarCurve(keys: keys)
        let end = 1.37, n = 20_000, dx = end / Double(n)
        var integral = 0.0
        for i in 0..<n { integral += c.value(at: try t((Double(i)+0.5)*dx))*dx }
        XCTAssertEqual(c.integral(from: .zero, to: try t(end)), integral, accuracy: 1e-7)
    }
    func testSourceBoundsAreExplicit() throws {
        let r = try SpeedRamp.constant(outputDuration: t(5), speed: -1, sourceOrigin: 2)
        XCTAssertThrowsError(try r.sample(at: t(4), range: 0...2, policy: .reject))
        XCTAssertEqual(try r.sample(at: t(4), range: 0...2, policy: .clamp), 0)
    }
    func testFrameScheduleHasNoTerminalDuplicate() throws {
        let s = try FrameSchedule(duration: t(1), rate: FrameRate(30))
        XCTAssertEqual(s.count, 30)
        XCTAssertEqual(try s.time(at: 29).seconds, 29.0/30, accuracy: 1e-12)
        XCTAssertThrowsError(try s.time(at: 30))
        XCTAssertEqual(try FrameSchedule(duration: .zero, rate: FrameRate(30)).count, 0)
    }
    func testRationalFrameScheduleIsExact() throws {
        for pair: (Int64, Int64) in [(24_000,1001), (30_000,1001), (60_000,1001), (120,1)] {
            let rate = try FrameRate(pair.0, pair.1)
            let duration = try rate.time(forFrame: 600)
            let schedule = try FrameSchedule(duration: duration, rate: rate)
            XCTAssertEqual(schedule.count, 600)
            XCTAssertEqual(try schedule.time(at: 599).rawValue, rate.ticksPerFrame * 599)
        }
    }
    func testFrameInputAndResourceLimits() throws {
        XCTAssertThrowsError(try FrameRate(0))
        XCTAssertThrowsError(try FrameRate(30, 0))
        XCTAssertThrowsError(try FrameRate(30).time(forFrame: Int64.max))
        XCTAssertThrowsError(try FrameSchedule(duration: t(10), rate: FrameRate(30), maxFrames: 100))
        XCTAssertThrowsError(try FrameSchedule(duration: t(-1), rate: FrameRate(30)))
    }
    func testDocumentRoundTripAndFutureVersionRejection() throws {
        let d = try TimingDocument(mode: .speedRamp, keys: [key(0, 1), key(2, 2)], sourceOrigin: 3)
        XCTAssertEqual(try JSONDecoder().decode(TimingDocument.self, from: d.encoded()), d)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: d.encoded()) as? [String:Any])
        json["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(TimingDocument.self, from: future))
    }
    func testDecodedInvalidCurveIsRejected() throws {
        let d = try TimingDocument(mode: .property, keys: [key(0, 1), key(1, 2)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: d.encoded()) as? [String:Any])
        var keys = try XCTUnwrap(json["keys"] as? [[String:Any]])
        keys[1]["time"] = keys[0]["time"]
        json["keys"] = keys
        XCTAssertThrowsError(try JSONDecoder().decode(TimingDocument.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testUndoRedoAndInvalidCommitAreTransactional() throws {
        let first = try TimingDocument(mode: .property, keys: [key(0, 1), key(1, 2)])
        var history = try DocumentHistory(initial: first, limit: 2)
        var next = first
        next.keys[0].value = 5
        try history.commit(next)
        XCTAssertEqual(history.undo(), first)
        XCTAssertEqual(history.redo(), next)
        var invalid = next
        invalid.keys[0].value = .nan
        XCTAssertThrowsError(try history.commit(invalid))
        XCTAssertEqual(history.current, next)
    }
}
