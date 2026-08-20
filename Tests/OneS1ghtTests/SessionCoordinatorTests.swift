//
//  SessionCoordinatorTests.swift
//  라이프사이클 통합 — prepare(초기화)/start(가동) 분리 + Mock 프로바이더 + 스텁 서버
//

import XCTest
@testable import OneS1ght

@MainActor
final class SessionCoordinatorTests: XCTestCase {

    var provider: MockPositioningProvider!
    var identity: IdentityStore!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        provider = MockPositioningProvider()
        let defaults = UserDefaults(suiteName: "SessionCoordinatorTests")!
        defaults.removePersistentDomain(forName: "SessionCoordinatorTests")
        identity = IdentityStore(secure: InMemorySecureStore(), defaults: defaults)
    }

    private func makeCoordinator(flushThreshold: Int = 100) -> SessionCoordinator {
        SessionCoordinator(api: ApiClient(apiKey: "test-key",
                                          baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                                          session: makeStubSession()),
                           identity: identity,
                           flushThreshold: flushThreshold)
    }

    /// prepare + start 한 번에 (개별 단계는 아래 전용 테스트에서)
    private func makeStarted(flushThreshold: Int = 100) async throws -> SessionCoordinator {
        let c = makeCoordinator(flushThreshold: flushThreshold)
        try await c.prepare()
        c.identify(profileId: "pf_8a3c")
        try await c.start(provider: provider)
        return c
    }

    /// 경로별 canned 응답 (기본 세트)
    private func routeDefaults(floorStatus: Int = 200) {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            if path.hasSuffix("/positioning/buildings") {
                return (200, Data(#"""
                { "synced_at": "s", "buildings": [
                  { "building_id": "B1", "name": "금정역 skv1", "store_id": 3,
                    "floors": [ { "floor_id": "F", "name": "F" } ] } ] }
                """#.utf8))
            }
            if path.contains("/positioning/floors/") {
                if floorStatus == 404 { return (404, Data(#"{ "detail": "no zones" }"#.utf8)) }
                return (200, Data(#"""
                { "floor_id": "F", "building_id": null, "name": "F", "synced_at": "s",
                  "zones": [], "anchors": [] }
                """#.utf8))
            }
            if path.hasSuffix("/events/zone") {
                return (200, Data(#"""
                { "accepted": true, "event_id": "e1",
                  "triggers": [ { "trigger_id": "a1", "type": "coupon",
                                  "payload": { "title": "무료커피" } } ] }
                """#.utf8))
            }
            if path.hasSuffix("/positioning/logs") {
                return (200, Data(#"{ "accepted_count": 99 }"#.utf8))
            }
            return (500, Data())
        }
    }

    // prepare: verify 만. "세션 가능" 확정, 측위는 아직 안 돎.
    // 건물·층 조회는 prepare 의 책임이 아니다 — buildings()/loadFloor() 로 분리돼 있다.
    func testPrepare_verifiesKeyOnly() async throws {
        routeDefaults()
        let c = makeCoordinator()
        try await c.prepare()

        XCTAssertTrue(c.isPrepared)                              // 세션 가능
        XCTAssertFalse(provider.isRunning)                       // 측위는 아직
        XCTAssertEqual(StubURLProtocol.requests.map(\.path),
                       ["/api/sdk/v1/auth/verify"])        // buildings 는 부르지 않는다
        // verify 는 키 검증만 — 클라이언트 정보를 싣지 않는다
        let body = try JSONDecoder().decode(ReqVerify.self,
                                            from: XCTUnwrap(StubURLProtocol.requests[0].body))
        XCTAssertNil(body.client)
    }

    // start: provider 가동. consent 가 사라져 verify 재호출도 없어졌다.
    func testStart_afterPrepare_runsWithoutExtraVerify() async throws {
        routeDefaults()
        let c = try await makeStarted()

        XCTAssertTrue(provider.isRunning)
        XCTAssertTrue(c.visitorId.hasPrefix("v-"))
        // 층 미선택 상태 — SDK 가 임의로 건물·층을 고르지 않는다 (호스트가 loadFloor 를 부를 때까지)
        XCTAssertNil(provider.appliedBuildingId)
        XCTAssertNil(provider.appliedFloorId)
        // verify 는 prepare 의 1회뿐 — 동의 기록 목적의 재호출이 사라졌다
        let verifies = StubURLProtocol.requests.filter { $0.path.hasSuffix("/auth/verify") }
        XCTAssertEqual(verifies.count, 1)
        await c.stop()
    }

    // prepare 없이 start → notInitialized
    func testStart_withoutPrepare_throwsNotInitialized() async {
        routeDefaults()
        let c = makeCoordinator()
        do {
            try await c.start(provider: provider)
            XCTFail("notInitialized여야 함")
        } catch let e as SdkError {
            XCTAssertEqual(e, .notInitialized)
        } catch { XCTFail("SdkError여야 함") }
        XCTAssertFalse(provider.isRunning)
    }

    // 인증 게이팅 — identify 없이 start: 수집 미시작 (서버 요청도 안 나감)
    func testStart_withoutIdentify_doesNotStartCollection() async throws {
        routeDefaults()
        let c = makeCoordinator()
        try await c.prepare()
        let requestsAfterPrepare = StubURLProtocol.requests.count

        do {
            try await c.start(provider: provider)
            XCTFail("notIdentified여야 함")
        } catch let e as SdkError {
            XCTAssertEqual(e, .notIdentified)
        } catch { XCTFail("SdkError여야 함") }

        XCTAssertFalse(provider.isRunning)                        // 측위 미가동
        XCTAssertEqual(StubURLProtocol.requests.count, requestsAfterPrepare)  // 추가 요청 0
    }

    // positioning_enabled=false → prepare부터 실패 (세션 불가를 미리 앎)
    func testPrepare_positioningDisabled() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": false }"#.utf8))
        }
        let c = makeCoordinator()
        do {
            try await c.prepare()
            XCTFail("positioningDisabled여야 함")
        } catch let e as SdkError {
            XCTAssertEqual(e, .positioningDisabled)
        } catch { XCTFail("SdkError여야 함") }
        XCTAssertFalse(c.isPrepared)
    }

    // 존 판정 → events/zone 전송 (바디 검증) → triggers 호스트 콜백
    func testZoneEvent_sendsAndDeliversTriggers() async throws {
        routeDefaults()
        let c = try await makeStarted()

        let got = expectation(description: "triggers")
        c.onTriggers = { zoneId, triggers in
            XCTAssertEqual(zoneId, "Z1")
            XCTAssertEqual(triggers.first?.payload?["title"], "무료커피")
            got.fulfill()
        }
        provider.simulateZone("Z1", status: .enter, floorId: "F")
        await fulfillment(of: [got], timeout: 2)

        let zoneReq = StubURLProtocol.requests.first { $0.path.hasSuffix("/events/zone") }
        let body = try JSONDecoder().decode(ReqZoneEvent.self, from: XCTUnwrap(zoneReq?.body))
        XCTAssertEqual(body.zone_id, "Z1")
        XCTAssertEqual(body.status, .enter)
        XCTAssertEqual(body.visitor_id, c.visitorId)
        await c.stop()
    }

    // 좌표: 층설정 lazy 로드 + 임계(2건) 도달 시 자동 벌크 전송 (봉투 검증)
    func testPositions_bufferAndAutoFlushAtThreshold() async throws {
        routeDefaults()
        let c = try await makeStarted(flushThreshold: 2)

        // capturedAt 을 1초 간격으로 — 기본 4Hz(=0.25초) 다운샘플을 둘 다 통과한다.
        // 같은 시각으로 몰아 넣으면 두 번째가 솎여 버퍼가 임계에 닿지 않는다.
        let t0 = Date()
        provider.simulatePosition(Coordinates(x: 1, y: 2, z: 0), floorId: "F", at: t0)
        provider.simulatePosition(Coordinates(x: 3, y: 4, z: 0), floorId: "F",
                                  at: t0.addingTimeInterval(1))

        try await waitUntil { StubURLProtocol.requests.contains { $0.path.hasSuffix("/positioning/logs") } }

        let logReq = StubURLProtocol.requests.first { $0.path.hasSuffix("/positioning/logs") }
        let body = try JSONDecoder().decode(ReqPositionBulk.self, from: XCTUnwrap(logReq?.body))
        XCTAssertEqual(body.points.count, 2)
        XCTAssertEqual(body.points[0].coordinates, Coordinates(x: 1, y: 2, z: 0))
        XCTAssertEqual(body.visitor_id, c.visitorId)
        XCTAssertEqual(body.profile_id, "pf_8a3c")
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.path.contains("/positioning/floors/F") })
        await c.stop()
    }

    // floors 404 = "존 없음" 정상 분기 — 좌표 수집은 계속
    func testFloors404_isNormalBranch_positionsStillFlow() async throws {
        routeDefaults(floorStatus: 404)
        let c = try await makeStarted(flushThreshold: 1)

        provider.simulatePosition(Coordinates(x: 1, y: 1, z: 0), floorId: "F")
        try await waitUntil { StubURLProtocol.requests.contains { $0.path.hasSuffix("/positioning/logs") } }

        try await waitUntil { c.floorConfigs["F"] != nil }
        XCTAssertEqual(c.floorConfigs["F"]?.zones.count, 0)      // 빈 설정으로 마킹 (재조회 방지)
        await c.stop()
    }

    // stop → 잔여 좌표 flush. 초기화 상태는 유지 (재시작 가능)
    func testStop_flushesRemainder_staysPrepared() async throws {
        routeDefaults()
        let c = try await makeStarted(flushThreshold: 100)
        provider.simulatePosition(Coordinates(x: 9, y: 9, z: 0), floorId: "F")

        await c.stop()

        XCTAssertTrue(StubURLProtocol.requests.contains { $0.path.hasSuffix("/positioning/logs") })
        XCTAssertEqual(c.buffer.count, 0)
        XCTAssertFalse(provider.isRunning)
        XCTAssertTrue(c.isPrepared)                              // 초기화는 살아있음 → start 재호출 가능
    }

    // MARK: - position_rate_hz 다운샘플

    // 기본 4Hz — 0.05초 간격으로 20개를 넣어도 서버로 가는 건 솎인 소수뿐.
    // 앱 콜백(onPosition)과 존 판정은 원속도를 유지하므로 여기서 검증하지 않는다.
    func testPositionRate_downsamplesServerUploadsOnly() async throws {
        routeDefaults()
        let c = try await makeStarted(flushThreshold: 1000)   // flush 안 나게 크게

        let t0 = Date()
        for i in 0..<20 {
            provider.simulatePosition(Coordinates(x: Double(i), y: 0, z: 0), floorId: "F",
                                      at: t0.addingTimeInterval(Double(i) * 0.05))
        }
        // 1초 구간에 4Hz → 최대 5개 안팎 (경계 여유 10% 포함)
        XCTAssertLessThanOrEqual(c.buffer.count, 6)
        XCTAssertGreaterThanOrEqual(c.buffer.count, 4)
        await c.stop()
    }

    // 서버가 내려준 rate 를 반영한다 — 20Hz 면 0.05초 간격이 전부 통과.
    func testPositionRate_serverValueApplied() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"""
                { "valid": true, "tenant_code": "t", "positioning_enabled": true,
                  "position_rate_hz": 20 }
                """#.utf8))
            }
            if path.contains("/positioning/floors/") {
                return (200, Data(#"""
                { "floor_id": "F", "building_id": null, "name": "F", "synced_at": "s",
                  "zones": [], "anchors": [] }
                """#.utf8))
            }
            return (200, Data(#"{ "accepted_count": 0 }"#.utf8))
        }
        let c = try await makeStarted(flushThreshold: 1000)
        XCTAssertEqual(c.positionRateHz, 20)

        let t0 = Date()
        for i in 0..<10 {
            provider.simulatePosition(Coordinates(x: Double(i), y: 0, z: 0), floorId: "F",
                                      at: t0.addingTimeInterval(Double(i) * 0.05))
        }
        XCTAssertEqual(c.buffer.count, 10)                    // 전부 통과
        await c.stop()
    }

    // 범위 밖 값은 1~100 으로 접는다 (서버가 접어 보내지만 SDK 도 방어).
    func testPositionRate_outOfRangeClamped() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"""
                { "valid": true, "tenant_code": "t", "positioning_enabled": true,
                  "position_rate_hz": 9999 }
                """#.utf8))
            }
            return (200, Data(#"{ "accepted_count": 0 }"#.utf8))
        }
        let c = makeCoordinator()
        try await c.prepare()
        XCTAssertEqual(c.positionRateHz, SdkDefaults.maxRateHz)
    }

    /// 비동기 조건 폴링 (최대 2초)
    private func waitUntil(_ cond: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("조건 미충족 (2초)")
    }
}
