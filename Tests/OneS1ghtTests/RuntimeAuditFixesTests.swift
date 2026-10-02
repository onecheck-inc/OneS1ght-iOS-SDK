//
//  RuntimeAuditFixesTests.swift
//  2026-10-02 전수 조사(S1·S5·S7·S9~S18·S23)에서 찾은 코어 결함 — 고친 동작을 못 박는다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class RuntimeAuditFixesTests: XCTestCase {

    private var provider: MockPositioningProvider!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        provider = MockPositioningProvider()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func point(_ i: Int) -> PositionPoint {
        PositionPoint(floor_id: "F", coordinates: Coordinates(x: Double(i), y: 0, z: 0),
                      captured_at: "t\(i)")
    }

    // MARK: - S1 전송 중 empty()

    /// 전송이 도는 동안 공개 API empty() 가 버퍼를 비워도 죽지 않는다(예전: removeFirst 크래시).
    func testEmptyDuringFlushDoesNotCrash() async {
        var buffer: TrajectoryBuffer!
        buffer = TrajectoryBuffer(maxPerRequest: 2) { _ in
            buffer.empty()                       // 전송 도중에 비운다
            return true
        }
        (1...5).forEach { buffer.add(point($0)) }
        await buffer.flush()
        XCTAssertEqual(buffer.count, 0)
    }

    /// 비운 뒤 새로 쌓인 점은 지우지 않는다 — 보낸 배치는 이미 버려진 것이다.
    func testEmptyDuringFlushKeepsPointsAddedAfterward() async {
        var buffer: TrajectoryBuffer!
        var calls = 0
        buffer = TrajectoryBuffer(maxPerRequest: 10) { [self] _ in
            calls += 1
            if calls == 1 {
                buffer.empty()
                buffer.add(point(99))            // 비운 뒤 새 점
                return true
            }
            return false                          // 두 번째 전송은 실패 — 새 점은 남아야 한다
        }
        (1...3).forEach { buffer.add(point($0)) }
        await buffer.flush()
        XCTAssertEqual(buffer.points.map(\.captured_at), ["t99"])
    }

    // MARK: - S5 오프라인 폭주

    /// 임계를 넘어선 뒤 전송이 계속 실패해도 좌표마다 새 전송을 시도하지 않는다.
    func testFailedFlushIsNotRetriedOnEveryPoint() async throws {
        Fixture.route(["/positioning/logs": (500, "{}"), "/logs": (500, "{}")])
        let c = try await Fixture.started(provider, flushThreshold: 2)
        let t0 = Date()
        for i in 0..<12 {
            provider.simulatePosition(Coordinates(x: Double(i), y: 0, z: 0), floorId: "F",
                                      at: t0.addingTimeInterval(Double(i)))
        }
        await waitUntil { !Fixture.requests(endingWith: "/positioning/logs").isEmpty }
        await settle(0.2)
        XCTAssertEqual(Fixture.requests(endingWith: "/positioning/logs").count, 1,
                       "실패 뒤에는 60초 타이머가 다시 보낸다 — 좌표마다 보내면 초당 요청이 폭주한다")
        c.teardown()
    }

    /// 로그 전송이 실패하면 잠시 쉰다 — ERROR 가 날 때마다 즉시 다시 보내지 않는다.
    func testLogBufferBacksOffAfterFailure() async {
        var sends = 0
        var clock = Date()
        let buffer = SdkLogBuffer(minBackoff: 5, now: { clock }) { _ in sends += 1; return false }
        let entry = SdkLogEntry(code: "E5001", level: "ERROR", message: "", at: "t")
        buffer.add(entry)
        await waitUntil { sends == 1 }
        for _ in 0..<5 { buffer.add(entry) }
        await settle()
        XCTAssertEqual(sends, 1, "쉬는 동안 ERROR 마다 다시 보내면 안 된다")

        clock = clock.addingTimeInterval(6)        // 대기 시간이 지나면 다시 시도한다
        buffer.add(entry)
        await waitUntil { sends == 2 }
    }

    // MARK: - S7 비활성 상태의 재시도

    /// 앱이 잠깐 비활성(제어 센터 등)이면 재시도를 버리지 않고, 활성이 되면 켠다.
    func testRestartWaitsWhileInactiveInsteadOfDropping() async throws {
        Fixture.route()
        let c = try await Fixture.started(provider, engineRestartDelays: [0.01])
        var active = false
        c.isAppActive = { active }

        provider.simulateUnexpectedStop(retryable: true)
        await settle(0.1)
        XCTAssertEqual(provider.startCount, 1, "비활성 동안은 켜지 않는다")

        active = true
        await waitUntil { self.provider.startCount == 2 }
        XCTAssertTrue(c.isRunning)
        await c.stop()
    }

    // MARK: - S9 내려가는 동안의 판정

    /// stop 이 잔여 좌표를 보내며 기다리는 동안 늦게 온 존 판정은 끝난 세션으로 나가지 않는다.
    func testZoneEventDuringStopIsDropped() async throws {
        Fixture.route(["/positioning/logs": (200, #"{ "accepted_count": 1 }"#)])
        StubURLProtocol.handler = { [handler = StubURLProtocol.handler] req in
            if req.url?.path.hasSuffix("/positioning/logs") == true { Thread.sleep(forTimeInterval: 0.3) }
            return handler!(req)
        }
        let c = try await Fixture.started(provider)
        provider.simulatePosition(Coordinates(x: 1, y: 1, z: 0), floorId: "F")

        let stopping = Task { await c.stop() }
        await waitUntil { c.isStopping }
        provider.simulateZone("Z1", status: .enter, floorId: "F")
        await stopping.value

        XCTAssertTrue(Fixture.requests(endingWith: "/events/zone").isEmpty)
    }

    // MARK: - S10 · S11 구역 새로고침

    private func routeFloors(slowSecondZonesForA: Bool = false) {
        var zonesACalls = 0
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") { return (200, Data(Fixture.verifyOK.utf8)) }
            if path.hasSuffix("/config") { return (200, Data(#"{ "geo_sdk_key": "gsk_x" }"#.utf8)) }
            if path.hasSuffix("/plan") { return (200, Data(#"{"has_plan":false,"plan":null}"#.utf8)) }
            if path.hasSuffix("/anchors") { return (200, Data(#"{"anchors":[]}"#.utf8)) }
            if path.hasSuffix("/floor/A/zones") {
                zonesACalls += 1
                if slowSecondZonesForA, zonesACalls >= 2 { Thread.sleep(forTimeInterval: 0.3) }
                return (200, Data(#"{"zones":[{"zone_id":"za","name":"A구역","is_active":true,"polygon":[[0,0],[1,0],[1,1]]}]}"#.utf8))
            }
            if path.hasSuffix("/floor/B/zones") {
                return (200, Data(#"{"zones":[{"zone_id":"zb","name":"B구역","is_active":true,"polygon":[[0,0],[1,0],[1,1]]}]}"#.utf8))
            }
            return (200, Data(#"{ "accepted_count": 1 }"#.utf8))
        }
    }

    /// 새로고침을 기다리는 사이 층이 바뀌면 그 결과를 새 층에 넣지 않는다.
    func testRefreshZonesDoesNotWriteIntoAnotherFloor() async throws {
        routeFloors(slowSecondZonesForA: true)
        let c = Fixture.coordinator()
        try await c.prepare()
        try await c.setFloorMap(Floor(id: "A", name: "A"), buildingId: "B1")

        let refresh = Task { await c.refreshZones() }
        await waitUntil { StubURLProtocol.requests.filter { $0.path.hasSuffix("/floor/A/zones") }.count == 2 }
        try await c.setFloorMap(Floor(id: "B", name: "B"), buildingId: "B1")
        _ = await refresh.value

        XCTAssertEqual(c.floorState?.floorId, "B")
        XCTAssertEqual(c.floorState?.zones.map(\.id), ["zb"], "B 층에 A 층 구역이 들어가면 안 된다")
        c.teardown()
    }

    /// 구역이 그대로면 판정기를 다시 물리지 않는다 — 다시 물리면 체류 타이머가 지워진다.
    func testRefreshWithSameZonesDoesNotReapply() async throws {
        routeFloors()
        let c = Fixture.coordinator()
        try await c.prepare()
        c.identify(profileId: "pf")
        try await c.setFloorMap(Floor(id: "A", name: "A"), buildingId: "B1")
        try await c.start(provider: provider)
        let applied = provider.applyConfigCount

        _ = await c.refreshZones()
        _ = await c.refreshZones()
        XCTAssertEqual(provider.applyConfigCount, applied, "안 바뀐 구역을 다시 넣으면 체류가 영영 안 나온다")
        XCTAssertEqual(provider.reloadGeofencesCount, 0)
        await c.stop()
        c.teardown()
    }

    // MARK: - S12 identify 를 먼저 부른 경우

    func testIdentifyBeforeInitializeKeepsProfile() async throws {
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
        await OneS1ght.reset()
        Fixture.route()

        OneS1ght.identify(profileId: "pf_early")
        try await OneS1ght.initialize(sdkKey: "ock_identify_first", baseURL: Fixture.baseURL)
        let session = try OneS1ght.floorSession()
        try await session.begin(provider: provider)       // 예전: E1004(notIdentified)
        XCTAssertTrue(session.isRunning)

        await session.end()
        OneS1ght.identify(profileId: nil)
        await OneS1ght.reset()
    }

    // MARK: - S13 프로필 연결 전 로그

    /// initialize 중 E1007 은 프로필이 없어 못 보낸다 — 버리지 말고 identify 때 보낸다.
    func testLogsBeforeIdentifyAreSentAfterIdentify() async throws {
        Fixture.route(["/config": (500, "{}")])            // → E1007
        let c = Fixture.coordinator()
        try await c.prepare()
        await settle()
        XCTAssertTrue(Fixture.requests(endingWith: "/logs").isEmpty, "프로필이 없으면 보낼 곳이 없다")

        c.identify(profileId: "pf")
        await waitUntil { !Fixture.requests(endingWith: "/logs").isEmpty }
        let body = try XCTUnwrap(Fixture.requests(endingWith: "/logs").first?.body)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("E1007"))
    }

    // MARK: - S15 baseURL

    /// 공간 조회도 initialize(baseURL:) 로 받은 서버로 간다(예전: prod 고정).
    func testSpaceQueriesUseConfiguredBaseURL() async throws {
        routeFloors()
        let c = Fixture.coordinator()
        try await c.prepare()
        _ = try? await c.buildings()

        let hosts = StubURLProtocol.urls.filter { $0.path.hasSuffix("/positioning/buildings") }.map(\.host)
        XCTAssertEqual(hosts, ["stub.test"])
    }

    // MARK: - S16 도면 캐시

    func testPlanChangedInvalidatesPlanCache() async throws {
        routeFloors()
        let c = Fixture.coordinator()
        try await c.prepare()
        _ = try await c.floor(buildingId: "B1", floorId: "A")
        _ = try await c.floor(buildingId: "B1", floorId: "A")
        XCTAssertEqual(Fixture.requests(endingWith: "/plan").count, 1, "캐시가 있으면 다시 받지 않는다")

        c.deliverConfigChange(.planChanged(floorId: "A"))
        _ = try await c.floor(buildingId: "B1", floorId: "A")
        XCTAssertEqual(Fixture.requests(endingWith: "/plan").count, 2, "도면이 바뀌면 다시 받아야 한다")
    }

    // MARK: - S18 종료 뒤 실시간 연결

    func testEndWithoutFloorDetachesLiveStream() async throws {
        Fixture.route()
        let c = try await Fixture.started(provider)
        XCTAssertTrue(c.isLiveStreamAttached)
        await c.stop()
        XCTAssertFalse(c.isLiveStreamAttached, "층도 측위도 없으면 연결을 남기지 않는다")
    }

    // MARK: - K9 같은 사건은 한 줄

    /// 초기화 완료는 화면 로그에 한 줄만 — 코드 줄과 번역 문구 줄이 따로 찍히지 않는다.
    /// 코드 줄의 등급은 서버 등급과 같은 세기다(예전엔 전부 .log 였다).
    func testOneLinePerReportedEvent() async throws {
        Fixture.route(["/config": (500, "{}")])            // → E1007 도 남는다
        let c = Fixture.coordinator()
        var lines: [(LogLevel, String)] = []
        c.onLog = { lines.append(($0, $1)) }
        try await c.prepare()

        XCTAssertEqual(lines.filter { $0.1.contains("tenant") }.count, 1, "\(lines)")
        let keyLines = lines.filter { $0.1.contains("[E1007]") || $0.1.contains(SdkLocalized.text("coord.keyUnavailable")) }
        XCTAssertEqual(keyLines.count, 1, "\(lines)")
        XCTAssertEqual(keyLines.first?.0, .error)
    }

    // MARK: - S17 관대한 디코딩

    func testZoneEventResponseIsReadElementByElement() throws {
        let json = #"""
        { "accepted": true, "event_id": 123,
          "triggers": [ { "trigger_id": 7, "type": "coupon", "payload": { "title": "무료" } },
                        { "type": 5 },
                        null,
                        { "trigger_id": "t2", "type": "signage" } ] }
        """#
        let res = try JSONDecoder().decode(ResZoneEvent.self, from: Data(json.utf8))
        XCTAssertEqual(res.event_id, "123")
        XCTAssertEqual(res.triggers.map(\.triggerId), ["7", "", "t2"])
        XCTAssertEqual(res.triggers.first?.payload?["title"], "무료")
    }

    func testPositionBulkResponseWithoutCountIsStillSuccess() throws {
        let res = try JSONDecoder().decode(ResPositionBulk.self, from: Data(#"{ "ok": true }"#.utf8))
        XCTAssertNil(res.accepted_count)
    }

    /// 구역 하나가 틀려도 그 층 구역 전체가 비지 않는다.
    func testOneBadZoneDoesNotEmptyTheFloor() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            {"zones":[
              {"zone_id":"z1","name":"정상","is_active":true,"polygon":[[0,0],[1,0],[1,1]]},
              {"zone_id":42,"name":"숫자 id","polygon":[[0,0],[2,0],[2,2]]},
              {"name":"id 없음","is_active":true,"polygon":[[0,0],[1,0],[1,1]]},
              {"zone_id":"z4","name":"짧은 점","is_active":true,"polygon":[[0,0],[1],[3,0],[3,3]]},
              {"zone_id":"z5","name":"점 부족","is_active":true,"polygon":[[0,0],[1],[2]]}
            ]}
            """#.utf8))
        }
        let client = SpaceServiceClient(keys: .init(sdk: "ock", space: "gsk"),
                                        consoleBaseURL: Fixture.baseURL, session: makeStubSession())
        let zones = try await client.loadZones(buildingId: "B", floorId: "F")
        XCTAssertEqual(zones.map(\.id), ["z1", "42", "z4"])
        XCTAssertEqual(zones.last?.polygon.count, 3, "값이 2개 미만인 점만 버린다(S23 — 예전엔 크래시)")
    }
}
