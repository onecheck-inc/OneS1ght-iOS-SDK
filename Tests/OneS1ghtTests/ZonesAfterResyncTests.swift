import XCTest
@testable import OneS1ght

/**
 **실시간 재연결 뒤에도 존은 같은 자리에 있어야 한다.**

 실시간 연결이 붙을 때마다(.resyncNeeded) SDK 는 도면 캐시를 비운다(invalidatePlan). 예전엔 그 직후의
 존 새로고침(loadZones)이 캐시가 빈 것을 「도면 없음」 으로 읽어, 도면 있는 층의 px 존을 미터로 그대로
 썼다 — 존이 도면이 뜨자마자 수백 미터 밖으로 밀려 지도에서 사라졌다(2026-10-16 실기기).
 */
@MainActor
final class ZonesAfterResyncTests: XCTestCase {

    private func client() -> SpaceServiceClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return SpaceServiceClient(keys: .init(sdk: "ock_sdk_x", space: "gsk_x"),
                                  session: URLSession(configuration: cfg))
    }

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    /// 도면 10m × 5m · 100×50px (1m = 10px). 존은 콘솔이 px 로 내려준다.
    private func stubFloorWithPlan() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/plan") {
                return (200, Data("""
                {"has_plan":true,"floor_name":"1F","plan":{"image":
                  {"data_url":"data:image/png;base64,\(png)","width_m":10.0,
                   "img_w":100,"img_h":50,"origin_x":0.0,"origin_y":0.0}}}
                """.utf8))
            }
            if path.hasSuffix("/anchors") { return (200, Data(#"{"anchors":[]}"#.utf8)) }
            if path.contains("zone") {
                return (200, Data("""
                {"zones":[{"zone_id":"z-1","name":"A","is_active":true,
                  "polygon":[[20,10],[60,10],[60,40],[20,40]]}]}
                """.utf8))
            }
            return (404, Data())
        }
    }

    private func xy(_ zones: [Zone]) -> [[Double]] {
        (zones.first?.polygon ?? []).map { [$0.x, $0.y] }
    }

    func testZonesKeepMetersAfterPlanCacheIsCleared() async throws {
        stubFloorWithPlan()
        let c = client()

        let state = try await c.loadFloorState(buildingId: "b-1", floorId: "14")
        let before = xy(state.zones)
        XCTAssertEqual(before, [[2, 4], [6, 4], [6, 1], [2, 1]], "px → m (도면 축척)")

        c.invalidatePlan(floorId: nil)          // 실시간 재연결(.resyncNeeded)이 하는 일
        let after = xy(try await c.loadZones(buildingId: "b-1", floorId: "14"))

        XCTAssertEqual(after, before, "재연결 뒤 존이 px 를 미터로 읽어 다른 자리로 갔다")
    }

    /// 도면이 없는 층은 예전처럼 미터 그대로 — 회귀 방지.
    func testFloorWithoutPlanStillReadsMetersAfterClear() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/plan") { return (200, Data(#"{"has_plan":false,"plan":null}"#.utf8)) }
            if path.contains("zone") {
                return (200, Data("""
                {"zones":[{"zone_id":"z-1","name":"A","is_active":true,
                  "polygon":[[2.5,3.5],[7.5,3.5],[7.5,9.0],[2.5,9.0]]}]}
                """.utf8))
            }
            return (404, Data())
        }
        let c = client()
        c.invalidatePlan(floorId: nil)
        let zones = try await c.loadZones(buildingId: "b-1", floorId: "14")
        XCTAssertEqual(xy(zones), [[2.5, 3.5], [7.5, 3.5], [7.5, 9.0], [2.5, 9.0]])
    }
}
