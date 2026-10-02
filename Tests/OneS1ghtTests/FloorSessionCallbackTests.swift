//
//  FloorSessionCallbackTests.swift
//  FloorSession 의 콜백·일시정지가 어느 provider 로 시작해도 같은 길로 오는가
//  (2026-10-02 감사 S6·S20·K14).
//

import XCTest
@testable import OneS1ght

@MainActor
final class FloorSessionCallbackTests: XCTestCase {

    private var provider: MockPositioningProvider!
    private var session: FloorSession!

    override func setUp() async throws {
        try await super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        Fixture.route()
        await OneS1ght.reset()
        provider = MockPositioningProvider()
        try await OneS1ght.initialize(sdkKey: "ock_floor_session_callbacks", baseURL: Fixture.baseURL)
        OneS1ght.identify(profileId: "pf_cb")
        session = try OneS1ght.floorSession()
    }

    override func tearDown() async throws {
        session.onFloorDetected = nil
        session.onStopped = nil
        session.onZoneEnter = nil
        session.onZoneDwell = nil
        await OneS1ght.reset()
        OneS1ght.identify(profileId: nil)
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    private var zone: Zone {
        Zone(id: "z1", name: "입구", polygon: [Position(x: 0, y: 0), Position(x: 1, y: 0), Position(x: 1, y: 1)])
    }

    /// S6 — README 가 안내하던 onFloorDetected 가 실제로 온다.
    func testFloorDetectedReachesSession() async throws {
        var got: [String?] = []
        session.onFloorDetected = { got.append($0) }
        try await session.begin(provider: provider)
        provider.simulateFloorDetected("14")
        provider.simulateFloorDetected(nil)
        XCTAssertEqual(got, ["14", nil])
    }

    /// S6 — end() 는 onStopped(.ended) 를 낸다.
    func testEndFiresOnStopped() async throws {
        var reasons: [FloorSession.StopReason] = []
        session.onStopped = { reasons.append($0) }
        try await session.begin(provider: provider)
        await session.end()
        XCTAssertEqual(reasons, [.ended])
    }

    /// S6 — 엔진이 포기해 SDK 가 세션을 닫으면 앱이 안다(.engineFailed).
    func testEngineGiveUpFiresOnStopped() async throws {
        var reasons: [FloorSession.StopReason] = []
        session.onStopped = { reasons.append($0) }
        try await session.begin(provider: provider)
        provider.simulateUnexpectedStop(retryable: false)
        await waitUntil { reasons == [.engineFailed] }
        XCTAssertFalse(session.isRunning)
    }

    /// K14 — begin(provider:) 로 시작해도 구역 콜백이 온다(예전엔 내장 provider 에만 물려 있었다).
    func testZoneCallbacksArriveForInjectedProvider() async throws {
        var entered: [String] = []
        var dwelt: [TimeInterval] = []
        session.onZoneEnter = { entered.append($0.id) }
        session.onZoneDwell = { _, s in dwelt.append(s) }
        try await session.begin(provider: provider)
        provider.simulateZoneEvent(.enter(zone: zone, at: Date()))
        provider.simulateZoneEvent(.dwell(zone: zone, seconds: 10, at: Date()))
        XCTAssertEqual(entered, ["z1"])
        XCTAssertEqual(dwelt, [10])
        await session.end()
        provider.simulateZoneEvent(.enter(zone: zone, at: Date()))
        XCTAssertEqual(entered, ["z1"], "끝난 세션의 구역 이벤트는 앱에 가지 않는다")
    }

    /// K14 — 일시정지가 형변환 없이 어느 provider 에나 간다.
    func testPauseGoesThroughAnyProvider() async throws {
        try await session.begin(provider: provider)
        session.pause()
        XCTAssertTrue(session.isPaused)
        XCTAssertTrue(provider.isPaused)
        session.resume()
        XCTAssertFalse(session.isPaused)
        await session.end()
    }

    /// S20 — provider 를 껐다 켜도(백그라운드·재시도) 일시정지는 남는다. 풀리는 것은 end()·begin() 뿐이다.
    func testPauseSurvivesProviderRestartButNotEnd() async throws {
        try await session.begin(provider: provider)
        session.pause()
        provider.stop(); provider.start()            // 생명주기 정지·재시작과 같은 모양
        XCTAssertTrue(session.isPaused, "백그라운드에 다녀왔다고 일시정지가 풀리면 안 된다")

        await session.end()
        XCTAssertFalse(provider.isPaused, "끝낸 세션에 일시정지를 남기지 않는다")
    }

    /// S20 — 지난 세션의 일시정지가 남은 provider 로 begin 해도 정상 상태로 시작한다.
    func testBeginStartsUnpaused() async throws {
        provider.pause()
        try await session.begin(provider: provider)
        XCTAssertFalse(session.isPaused)
        await session.end()
    }
}
