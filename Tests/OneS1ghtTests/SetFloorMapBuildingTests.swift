//
//  SetFloorMapBuildingTests.swift
//  `setFloorMap(floor)` 를 건물 없이 부르면 조용히 층을 비우지 않고 던진다(2026-10-03 안드 감사 SF-A1 — 안드로이드와 같은 값).
//
//  예전엔 건물 인자도, 직전 건물도 없으면 「층 해제」 로 처리했다 — 호출은 성공하는데 층·구역이 비어 구역 이벤트가
//  0건이 되고, 이유는 어디에도 안 남았다. 이제 `SdkError.floorNotSet`(E3001)을 던지고 층 상태는 그대로 둔다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class SetFloorMapBuildingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") { return (200, Data(Fixture.verifyOK.utf8)) }
            if path.hasSuffix("/config") { return (200, Data(#"{ "geo_sdk_key": "gsk_x" }"#.utf8)) }
            if path.hasSuffix("/plan") { return (200, Data(#"{"has_plan":false,"plan":null}"#.utf8)) }
            if path.hasSuffix("/anchors") { return (200, Data(#"{"anchors":[]}"#.utf8)) }
            if path.hasSuffix("/zones") {
                return (200, Data(#"{"zones":[{"zone_id":"za","name":"A구역","is_active":true,"polygon":[[0,0],[1,0],[1,1]]}]}"#.utf8))
            }
            return (200, Data("{}".utf8))
        }
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// 층은 있는데 건물이 없으면 던지고, 지금 층은 그대로 둔다. E3001 도 남긴다.
    func testFloorWithoutBuildingThrowsAndKeepsCurrentFloor() async throws {
        let c = Fixture.coordinator()
        var lines: [String] = []
        c.onLog = { _, msg in lines.append(msg) }
        try await c.prepare()
        try await c.setFloorMap(Floor(id: "A", name: "A"), buildingId: "B1")

        do {
            try await c.setFloorMap(Floor(id: "B", name: "B"), buildingId: nil)
            XCTFail("건물 없이 층을 지정했는데 성공했다 — 층이 조용히 비워진다")
        } catch let e as SdkError {
            XCTAssertEqual(e, .floorNotSet)
            XCTAssertEqual(e.code, .floorNotSet, "E3001")
        }
        XCTAssertEqual(c.floorState?.floorId, "A", "실패한 호출이 층을 지우면 안 된다")
        XCTAssertEqual(c.floorState?.zones.map(\.id), ["za"])
        XCTAssertTrue(lines.contains { $0.contains("E3001") }, "\(lines)")
        c.teardown()
    }

    /// `setFloorMap(nil)` — 명시적 해제는 그대로 허용한다.
    func testNilFloorStillClears() async throws {
        let c = Fixture.coordinator()
        try await c.prepare()
        try await c.setFloorMap(Floor(id: "A", name: "A"), buildingId: "B1")
        try await c.setFloorMap(nil, buildingId: nil)
        XCTAssertNil(c.floorState)
        c.teardown()
    }

    /// 공개 API: 처음부터 건물 없이 부르면 던진다. 건물을 한 번 넘긴 뒤로는 생략해도 직전 건물을 쓴다.
    func testFacadeUsesPreviousBuildingAndThrowsWithoutOne() async throws {
        URLProtocol.registerClass(StubURLProtocol.self)
        defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
        await OneS1ght.reset()
        try await OneS1ght.initialize(sdkKey: "ock_set_floor_building", baseURL: Fixture.baseURL)

        do {
            try await OneS1ght.setFloorMap(Floor(id: "A", name: "A"))
            XCTFail("건물 문맥 없이 성공했다")
        } catch let e as SdkError {
            XCTAssertEqual(e, .floorNotSet)
        }

        try await OneS1ght.setFloorMap(Floor(id: "A", name: "A"), buildingId: "B1")
        try await OneS1ght.setFloorMap(Floor(id: "B", name: "B"))      // 직전 건물 B1
        XCTAssertEqual(OneS1ght.coordinatorRef?.floorState?.buildingId, "B1")
        XCTAssertEqual(OneS1ght.coordinatorRef?.floorState?.floorId, "B")

        try await OneS1ght.setFloorMap(nil)                              // 해제 — 건물 문맥도 잊는다
        XCTAssertNil(OneS1ght.coordinatorRef?.floorState)
        do {
            try await OneS1ght.setFloorMap(Floor(id: "A", name: "A"))
            XCTFail("해제 뒤에는 건물을 다시 넘겨야 한다")
        } catch let e as SdkError {
            XCTAssertEqual(e, .floorNotSet)
        }
        await OneS1ght.reset()
    }
}
