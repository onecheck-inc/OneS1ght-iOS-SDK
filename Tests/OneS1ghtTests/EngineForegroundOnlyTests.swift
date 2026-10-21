//
//  EngineForegroundOnlyTests.swift
//  측위 엔진은 앱이 화면에 있을 때만 돈다(2026-10-16).
//
//  위치 '항상' 권한이 있으면 엔진이 걸어 둔 비콘 영역 때문에 iOS 가 앱을 배경에서 깨우고, 거기서 begin() 이
//  불려 엔진이 화면 없이 켜졌다. didEnterBackground 가 오지 않아 층 미탐지 감시(20초)·수신 점검이 정지된
//  앱 안에 걸린 채 남았고, 몇 분 뒤 앱을 열면 밀린 대기가 한꺼번에 깨어나 열자마자 E3007 이 떴다.
//  여기서 지키는 것: 화면 밖 시작은 엔진을 미루고, 화면에 오면 **한 번만** 켜고, 배경에선 끄고 타이머도 거둔다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class EngineForegroundOnlyTests: XCTestCase {

    private var provider: MockPositioningProvider!
    private var active = true
    private var regionClears = 0

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        Fixture.route(fallback: (200, #"{ "accepted_count": 0 }"#))
        provider = MockPositioningProvider()
        active = true
        regionClears = 0
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// prepare → identify 까지 하고, 화면 상태·영역 정리를 이 테스트가 보도록 바꿔 끼운다.
    private func prepared(receptionCheckDelay: TimeInterval = 7,
                          suite: String = #function) async throws -> SessionCoordinator {
        let c = Fixture.coordinator(suite: suite, receptionCheckDelay: receptionCheckDelay)
        c.isAppActive = { [unowned self] in self.active }
        c.clearStaleEngineRegion = { [unowned self] in self.regionClears += 1 }
        try await c.prepare()
        c.identify(profileId: "pf_8a3c")
        return c
    }

    /// 화면 밖에서 시작하면 세션은 열리지만 엔진은 켜지 않는다 — 남은 비콘 영역은 지운다.
    func testStartWhileInactiveDefersEngine() async throws {
        let c = try await prepared()
        var lines: [String] = []
        c.onLog = { _, line in lines.append(line) }
        active = false

        try await c.start(provider: provider)

        XCTAssertTrue(c.isRunning, "세션은 논리적으로 열려 있다")
        XCTAssertFalse(c.visitorId.isEmpty)
        XCTAssertEqual(provider.startCount, 0, "화면 밖에서는 엔진을 켜지 않는다")
        XCTAssertTrue(c.engineAwaitingForeground)
        XCTAssertEqual(regionClears, 1, "배경에서 깨어난 시작 — 남은 영역을 지운다")
        XCTAssertTrue(lines.contains(SdkLocalized.text("coord.engineDeferred")), "\(lines)")
        await c.stop()
    }

    /// 화면에 오면 한 번만 켠다 — willEnterForeground 와 didBecomeActive 가 둘 다 와도.
    func testBecomingActiveStartsEngineExactlyOnce() async throws {
        let c = try await prepared()
        active = false
        try await c.start(provider: provider)

        active = true
        c.handleDidBecomeActive()      // willEnterForeground
        c.handleDidBecomeActive()      // didBecomeActive
        c.handleDidBecomeActive()      // 제어 센터 뒤의 didBecomeActive

        XCTAssertEqual(provider.startCount, 1)
        XCTAssertTrue(provider.isRunning)
        XCTAssertFalse(c.engineAwaitingForeground)
        await c.stop()
    }

    /// 미뤄 둔 엔진은 화면에 오면서 수신 점검도 그때 건다(시작 시점이 아니라).
    func testReceptionCheckArmsOnlyAfterForegroundStart() async throws {
        let diag = DiagnosticProvider(diagnostic: PositioningDiagnostic(
            registeredCount: 4, receivedCount: 4, matchedCount: 4, missingAddresses: [], hasFix: true))
        let c = try await prepared(receptionCheckDelay: 0.01)
        active = false
        try await c.start(provider: diag)
        await settle(0.1)
        XCTAssertEqual(diag.reads, 0, "엔진을 안 켰으니 수신 점검도 걸지 않는다")

        active = true
        c.handleDidBecomeActive()
        await waitUntil("화면에 온 뒤 수신 점검이 돌지 않았다") { diag.reads > 0 }
        await c.stop()
    }

    /// 배경에서 끄고, 복귀하면 다시 켠다(한 번). 영역은 배경 정지 때 지우지 않는다 — 엔진이 스스로 푼다(2026-10-21).
    func testBackgroundStopThenForegroundRestarts() async throws {
        let c = try await prepared()
        try await c.start(provider: provider)
        XCTAssertEqual(provider.startCount, 1)
        XCTAssertEqual(regionClears, 0, "포그라운드 시작은 영역을 지우지 않는다 — 엔진이 다시 건다")

        active = false
        await c.handleDidEnterBackground()
        XCTAssertFalse(provider.isRunning)
        XCTAssertTrue(c.engineAwaitingForeground)
        XCTAssertEqual(regionClears, 0, "엔진보다 먼저 지우면 복귀 뒤 iOS 가 비콘 영역을 「밖」 으로 판정한다")

        active = true
        c.handleDidBecomeActive()
        c.handleDidBecomeActive()
        XCTAssertEqual(provider.startCount, 2)
        XCTAssertTrue(provider.isRunning)
        await c.stop()
    }

    /// 배경 정지는 수신 점검을 거둔다 — 걸어 두면 배경 시간까지 세어 복귀하자마자 깨어난다.
    func testBackgroundCancelsReceptionCheck() async throws {
        let diag = DiagnosticProvider(diagnostic: nil)
        let c = try await prepared(receptionCheckDelay: 0.1)
        try await c.start(provider: diag)

        await c.handleDidEnterBackground()
        await settle(0.25)
        XCTAssertEqual(diag.reads, 0, "배경으로 간 뒤 수신 점검이 깨어났다")

        c.handleDidBecomeActive()
        await waitUntil("복귀 뒤 수신 점검을 다시 걸지 않았다") { diag.reads > 0 }
        await c.stop()
    }

    /// 화면에 있을 때의 시작은 예전 그대로 — 바로 켜고, 활성 알림은 아무것도 하지 않는다.
    func testStartWhileActiveBehavesAsBefore() async throws {
        let c = try await prepared()
        try await c.start(provider: provider)

        XCTAssertEqual(provider.startCount, 1)
        XCTAssertTrue(provider.isRunning)
        XCTAssertFalse(c.engineAwaitingForeground)

        c.handleDidBecomeActive()      // 제어 센터 등 잠깐 inactive 였다 돌아옴
        XCTAssertEqual(provider.startCount, 1, "도는 엔진을 다시 건드리지 않는다")
        await c.stop()
    }

    /// 끝난 세션은 화면에 와도 켜지 않는다.
    func testBecomingActiveAfterStopDoesNothing() async throws {
        let c = try await prepared()
        active = false
        try await c.start(provider: provider)
        await c.stop()

        active = true
        c.handleDidBecomeActive()
        XCTAssertEqual(provider.startCount, 0)
    }

    /// 종료 알림 — 엔진을 그 자리에서 끄고 영역을 지운다.
    func testWillTerminateStopsEngineSynchronously() async throws {
        let c = try await prepared()
        try await c.start(provider: provider)

        c.handleWillTerminate()

        XCTAssertFalse(provider.isRunning)
        XCTAssertEqual(regionClears, 1)
        await c.stop()
    }

    #if canImport(UIKit)
    /// 실제 알림 경로 — 활성 알림이 미뤄 둔 엔진을 켠다.
    func testDidBecomeActiveNotificationStartsDeferredEngine() async throws {
        let c = try await prepared()
        active = false
        try await c.start(provider: provider)

        active = true
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { self.provider.startCount == 1 }
        await settle()
        XCTAssertEqual(provider.startCount, 1)
        await c.stop()
        c.teardown()
    }
    #endif
}
