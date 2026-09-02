import XCTest
@testable import OneS1ght

/**
 **로케이터를 못 받아도 층은 열린다.**

 예전에는 앵커 조회가 던졌고, `loadFloorState` 가 그걸 그대로 위로 올렸다. 그 바람에 조회가
 한 번 실패하면 앱에 **도면도 존도 격자도 안 그려지고** "지도 조회 실패" 만 떴다 —
 도면 없는 층이 층 전체를 무너뜨리던 것(v0.1.14 에서 고침)과 똑같은 모양이다.

 도면·존은 앵커와 **다른 경로**로 받아 오고 이미 손에 있다. 로케이터가 없다고 지도를
 통째로 지울 이유가 없다. 못 받으면 측위만 못 하면 된다.

 "못 받았다"(E3006)와 "층에 없다"(E3002)는 **다른 코드**로 남긴다 — 확인할 곳이
 앞은 연동·네트워크, 뒤는 현장이라 뭉치면 엉뚱한 데를 뒤지게 된다.
 */
@MainActor
final class GeospaceAnchorFetchFailureTests: XCTestCase {

    private func client() -> GeospaceClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return GeospaceClient(keys: .init(sdk: "ock_sdk_x", geospace: "gsk_x"),
                              session: URLSession(configuration: cfg))
    }

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    /// 앵커만 실패하고 도면·존은 멀쩡할 때.
    private func stubAnchorsFailing(_ status: Int) {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/anchors") { return (status, Data()) }      // ← 여기만 깨진다
            if path.hasSuffix("/plan") {
                return (200, Data("""
                {"has_plan":true,"floor_name":"607호","plan":{"image":
                  {"data_url":"data:image/png;base64,\(png)","width_m":10.0,
                   "img_w":100,"img_h":50,"origin_x":0.0,"origin_y":0.0}}}
                """.utf8))
            }
            if path.contains("zone") {
                return (200, Data("""
                {"zones":[{"zone_id":"z-1","name":"A","is_active":true,
                  "polygon":[[0.0,0.0],[5.0,0.0],[5.0,4.0],[0.0,4.0]]}]}
                """.utf8))
            }
            return (404, Data())
        }
    }

    /// ★ 핵심 — 앵커가 5xx 로 죽어도 **도면과 존은 그대로 온다.**
    func testFloorStillLoadsWhenAnchorFetchFails() async throws {
        stubAnchorsFailing(503)

        let state = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        XCTAssertTrue(state.hasPlan, "앵커가 죽었다고 도면까지 잃었다")
        XCTAssertEqual(state.zones.count, 1, "앵커가 죽었다고 존까지 잃었다")
        XCTAssertTrue(state.locators.isEmpty)
        XCTAssertNil(state.sessionId)
        XCTAssertTrue(state.locatorsFetchFailed, "못 받은 것을 못 받았다고 표시하지 않았다")
    }

    /// 404 도 마찬가지다 — 상류가 그 층의 앵커를 모른다는 것뿐, 지도를 지울 이유가 아니다.
    func testFloorStillLoadsWhenAnchorsAre404() async throws {
        stubAnchorsFailing(404)

        let state = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        XCTAssertTrue(state.hasPlan)
        XCTAssertEqual(state.zones.count, 1)
        XCTAssertTrue(state.locatorsFetchFailed)
    }

    /**
     "못 받았다" 와 "층에 없다" 는 다르다.
     빈 배열이 정상 응답으로 오면 `locatorsFetchFailed` 는 **거짓**이어야 한다 —
     그래야 E3002(현장 확인)와 E3006(연동 확인)이 갈린다.
     */
    func testAnEmptyAnchorListIsNotAFetchFailure() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/anchors") { return (200, Data(#"{"anchors":[]}"#.utf8)) }
            if path.hasSuffix("/plan") {
                return (200, Data("""
                {"has_plan":true,"floor_name":"607호","plan":{"image":
                  {"data_url":"data:image/png;base64,\(png)","width_m":10.0,
                   "img_w":100,"img_h":50,"origin_x":0.0,"origin_y":0.0}}}
                """.utf8))
            }
            if path.contains("zone") { return (200, Data(#"{"zones":[]}"#.utf8)) }
            return (404, Data())
        }

        let state = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        XCTAssertTrue(state.locators.isEmpty)
        XCTAssertFalse(state.locatorsFetchFailed, "빈 목록을 조회 실패로 오인했다")
    }

    /// `locators(_:_:)` 도 던지지 않는다 — 앱이 층을 여는 두 번째 관문이다.
    func testLoadLocatorsDoesNotThrowOnFailure() async {
        stubAnchorsFailing(500)

        let got = await client().loadLocators(buildingId: "b-1", floorId: "14")

        XCTAssertTrue(got.locators.isEmpty)
        XCTAssertNil(got.sessionId)
        XCTAssertFalse(got.positioningReady, "측위 불가로 떨어져야 한다")
    }
}
