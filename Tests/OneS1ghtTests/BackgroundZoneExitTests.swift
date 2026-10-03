//
//  BackgroundZoneExitTests.swift
//  앱이 배경으로 내려가 측위를 멈출 때 안에 있던 구역의 EXIT 가 서버로 가는가(2026-10-03 안드 감사 SP-B15).
//
//  배경에서는 UWB 가 멈춰 엔진이 OUT 을 주지 않는다. 예전엔 그대로 멈춰 서버에 ENTER 만 남았고, 복귀 후
//  같은 구역의 ENTER 가 EXIT 없이 한 번 더 갔다(쿠폰 중복 여지). 판정 쪽은 UwbAreaJudgeTests 가 본다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class BackgroundZoneExitTests: XCTestCase {

    private var provider: MockPositioningProvider!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        provider = MockPositioningProvider()
        Fixture.route(["/events/zone": (200, #"{ "triggers": [] }"#)])
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func zoneStatuses() -> [String] {
        Fixture.requests(endingWith: "/events/zone").compactMap { req in
            guard let body = req.body,
                  let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            return obj["status"] as? String
        }
    }

    /// 배경 전환: 정지 **전에** EXIT 를 내고(정지 뒤엔 provider 가 이벤트를 버린다) 서버에는 OUT 이 간다.
    func testBackgroundSendsExitBeforeStopping() async throws {
        let c = try await Fixture.started(provider)
        provider.simulateZone("Z1", status: .enter, floorId: "F")
        await waitUntil { self.zoneStatuses().count == 1 }

        provider.activeZoneId = "Z1"
        await c.handleDidEnterBackground()

        XCTAssertEqual(provider.exitBeforeBackgroundCount, 1)
        XCTAssertEqual(provider.wasRunningAtExitBeforeBackground, true, "정지한 뒤에 부르면 EXIT 가 버려진다")
        XCTAssertFalse(provider.isRunning, "배경에서는 측위를 멈춘다")
        await waitUntil { self.zoneStatuses().count == 2 }
        XCTAssertEqual(zoneStatuses(), ["IN", "OUT"])
        await c.stop()
    }

    /// 측위 세션이 없으면(시작 전·종료 뒤) 아무것도 내지 않는다.
    func testBackgroundWithoutSessionDoesNothing() async throws {
        let c = Fixture.coordinator()
        try await c.prepare()
        await c.handleDidEnterBackground()
        XCTAssertEqual(provider.exitBeforeBackgroundCount, 0)
        XCTAssertTrue(zoneStatuses().isEmpty)
        c.teardown()
    }

    /// 일시정지 중이면 내지 않는다(안드로이드와 같다) — 일시정지는 구역 이벤트를 막겠다는 약속이다.
    func testBackgroundWhilePausedSendsNoExit() async throws {
        let c = try await Fixture.started(provider)
        provider.activeZoneId = "Z1"
        provider.pause()

        await c.handleDidEnterBackground()
        await settle(0.1)

        XCTAssertEqual(provider.exitBeforeBackgroundCount, 1)
        XCTAssertTrue(zoneStatuses().isEmpty, "\(zoneStatuses())")
        await c.stop()
    }
}
