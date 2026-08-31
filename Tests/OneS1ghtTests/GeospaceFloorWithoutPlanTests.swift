import XCTest
@testable import OneS1ght

/**
 **도면이 없는 층은 오류가 아니다.**

 매장은 도면을 올리지만 산업 현장처럼 올릴 도면 자체가 없는 곳이 있다. 예전에는 도면을
 반드시 있는 것으로 보고 `getPlan` 이 던졌고, 그 바람에 도면뿐 아니라 **로케이터·세션·존까지
 통째로** 못 받아 그런 층은 측위 자체가 불가능했다 — 앱에는 "지도 조회 실패: decode" 로만
 보여서, 도면이 없다는 사실이 통신 오류로 둔갑했다.

 좌표는 도면이 아니라 로케이터 배치에서 나온다. 그러므로 도면이 없어도 측위는 정상이어야
 하고, 이 테스트가 지키는 것은 **"도면만 빠지고 나머지는 다 온다"** 이다.
 */
@MainActor
final class GeospaceFloorWithoutPlanTests: XCTestCase {

    private func client() -> GeospaceClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return GeospaceClient(keys: .init(sdk: "ock_sdk_x", geospace: "gsk_x"),
                              session: URLSession(configuration: cfg))
    }

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    /// 콘솔이 `has_plan: false` 를 주는 층 — 앵커·세션·존은 그대로 와야 한다.
    func testFloorWithoutPlanStillLoadsLocatorsSessionAndZones() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/plan") {
                // 콘솔 프록시가 "도면 없음" 을 **명시**한다.
                return (200, Data(#"{"has_plan":false,"floor_name":"3공장 2층","plan":null}"#.utf8))
            }
            if path.hasSuffix("/anchors") {
                return (200, Data("""
                {"anchors":[
                  {"uwbMac":"AABBCCDD9DD7","x":1.0,"y":2.0,"sessionId":4444,"clusterStatus":"auto_done"},
                  {"uwbMac":"AABBCCDD9DD8","x":8.0,"y":2.0,"sessionId":4444,"clusterStatus":"auto_done"}
                ]}
                """.utf8))
            }
            if path.contains("zone") {
                return (200, Data("""
                {"zones":[{"zone_id":"z-1","name":"작업구역 A","is_active":true,
                  "polygon":[[0.0,0.0],[5.0,0.0],[5.0,4.0],[0.0,4.0]]}]}
                """.utf8))
            }
            return (404, Data())
        }

        let state = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        // 도면만 없다.
        XCTAssertFalse(state.hasPlan)
        // 나머지는 전부 살아 있어야 한다 — 예전에는 여기까지 오지도 못했다.
        XCTAssertEqual(state.locators.count, 2)
        XCTAssertEqual(state.sessionId, 4444)
        XCTAssertEqual(state.zones.count, 1)
        XCTAssertEqual(state.zones.first?.name, "작업구역 A")
    }

    /// 도면이 없으면 존 폴리곤은 **미터로 그대로** 읽는다.
    /// 픽셀인지 미터인지를 가르는 기준이 도면 크기인데 그 도면이 없기 때문이다.
    func testZonePolygonIsReadAsMetersWhenNoPlan() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/plan") {
                return (200, Data(#"{"has_plan":false,"floor_name":"3공장 2층","plan":null}"#.utf8))
            }
            if path.hasSuffix("/anchors") { return (200, Data(#"{"anchors":[]}"#.utf8)) }
            if path.contains("zone") {
                return (200, Data("""
                {"zones":[{"zone_id":"z-1","name":"A","is_active":true,
                  "polygon":[[2.5,3.5],[7.5,3.5],[7.5,9.0],[2.5,9.0]]}]}
                """.utf8))
            }
            return (404, Data())
        }

        let state = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        let pts = try XCTUnwrap(state.zones.first?.polygon)
        XCTAssertEqual(pts.map(\.x), [2.5, 7.5, 7.5, 2.5])
        XCTAssertEqual(pts.map(\.y), [3.5, 3.5, 9.0, 9.0])
    }

    /// `has_plan: false` 면 GeoSpace 직행 폴백을 **타지 않는다.**
    ///
    /// 예전에 던지던 자리가 정확히 여기다 — 콘솔이 "없다" 고 말했는데도 폴백을 탔고,
    /// 그쪽 응답 타입은 이미지가 옵셔널이 아니라 디코드에서 터졌다.
    func testDoesNotFallBackToGeospaceWhenConsoleSaysNoPlan() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/plan") && path.contains("/positioning/") {
                return (200, Data(#"{"has_plan":false,"plan":null}"#.utf8))
            }
            if path.hasSuffix("/anchors") { return (200, Data(#"{"anchors":[]}"#.utf8)) }
            if path.contains("zone") { return (200, Data(#"{"zones":[]}"#.utf8)) }
            return (404, Data())
        }

        _ = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        // GeoSpace 직행 도면 경로(api/m/floors/…/plan)는 한 번도 불리지 않아야 한다.
        let geospacePlanCalls = StubURLProtocol.requests.filter {
            $0.path.hasSuffix("/plan") && $0.path.contains("api/m/floors")
        }
        XCTAssertTrue(geospacePlanCalls.isEmpty,
                      "콘솔이 도면 없음을 명시했는데 GeoSpace 폴백을 탔다: \(geospacePlanCalls.map(\.path))")
    }

    /// 도면이 **있는** 층은 예전 그대로 — 회귀 방지.
    func testFloorWithPlanStillReportsHasPlan() async throws {
        // 1×1 투명 PNG
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/plan") {
                return (200, Data("""
                {"has_plan":true,"floor_name":"607호","plan":{"image":
                  {"data_url":"data:image/png;base64,\(png)","width_m":10.0,
                   "img_w":100,"img_h":50,"origin_x":0.0,"origin_y":0.0}}}
                """.utf8))
            }
            if path.hasSuffix("/anchors") { return (200, Data(#"{"anchors":[]}"#.utf8)) }
            if path.contains("zone") { return (200, Data(#"{"zones":[]}"#.utf8)) }
            return (404, Data())
        }

        let state = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        XCTAssertTrue(state.hasPlan)
    }

    /// 서버가 `cluster_status` 로 미배치를 알려주면 로케이터에 실려 와야 한다 —
    /// 측위를 켜 보기 **전에도** 알 수 있는 유일한 고장 신호다.
    func testClusterStatusBecomesIsPlaced() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/plan") { return (200, Data(#"{"has_plan":false,"plan":null}"#.utf8)) }
            if path.hasSuffix("/anchors") {
                return (200, Data("""
                {"anchors":[
                  {"uwbMac":"AABBCCDD9DD7","x":1.0,"y":2.0,"sessionId":1,"clusterStatus":"auto_done"},
                  {"uwbMac":"AABBCCDD9DD8","x":2.0,"y":2.0,"sessionId":1,"clusterStatus":"apply_failed"},
                  {"uwbMac":"AABBCCDD9DD9","x":3.0,"y":2.0,"sessionId":1}
                ]}
                """.utf8))
            }
            if path.contains("zone") { return (200, Data(#"{"zones":[]}"#.utf8)) }
            return (404, Data())
        }

        let state = try await client().loadFloorState(buildingId: "b-1", floorId: "14")

        XCTAssertEqual(state.locators.map(\.isPlaced),
                       [true,    // auto_done
                        false,   // apply_failed → 미배치
                        true],   // 값이 없으면 배치된 것으로 본다 (모름을 고장으로 치지 않는다)
                       "cluster_status 해석이 바뀌었다")
    }
}
