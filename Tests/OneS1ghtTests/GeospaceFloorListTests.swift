import XCTest
@testable import OneS1ght

/**
 층 목록은 **도면을 받지 않는다.**

 예전에는 이름을 얻으려고 층마다 plan 을 불렀다. plan 응답은 prod 실측 888KB 라, 층이 N개면
 드롭다운이 뜨기 전에 888KB × N 을 순서대로 받았다 — 실기기에서 "빌딩을 고르면 층이 한참
 뒤에 뜬다"로 나타났다.

 이 테스트가 지키는 것은 **요청의 개수**다. 이름을 잘 채우는지만 보면, 누군가 다시 plan 을
 부르도록 되돌려도 통과해 버린다.
 */
@MainActor
final class GeospaceFloorListTests: XCTestCase {

    private func client() -> GeospaceClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return GeospaceClient(keys: .init(sdk: "ock_sdk_x", geospace: "gsk_x"),
                              session: URLSession(configuration: cfg))
    }

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    func testFloorListMakesExactlyOneRequestAndFillsNames() async throws {
        StubURLProtocol.handler = { req in
            guard req.url?.path.hasSuffix("/floors") == true else {
                return (500, Data())   // plan 을 부르면 여기 걸린다 — 아래 요청 수 단언이 잡는다
            }
            let body = """
            {"building_id":"b-1","floors":[
              {"floor_id":"14","name":"607호","has_plan":true},
              {"floor_id":"15","name":"304로","has_plan":false}
            ]}
            """
            return (200, Data(body.utf8))
        }

        let floors = try await client().loadFloors(buildingId: "b-1")

        XCTAssertEqual(floors.map(\.id), ["14", "15"])
        XCTAssertEqual(floors.map(\.name), ["607호", "304로"])
        XCTAssertEqual(floors.map(\.hasPlan), [true, false])
        // 핵심 — 층이 2개여도 왕복은 1회다.
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertTrue(StubURLProtocol.requests[0].path.hasSuffix("/floors"))
    }

    /// 콘솔 배포 시차 — name·has_plan 이 아직 없던 응답에도 깨지지 않아야 한다.
    func testFloorListSurvivesResponseWithoutNameOrHasPlan() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"building_id":"b-1","floors":[{"floor_id":"14"}]}"#.utf8))
        }

        let floors = try await client().loadFloors(buildingId: "b-1")

        XCTAssertEqual(floors.count, 1)
        XCTAssertEqual(floors[0].id, "14")
        XCTAssertFalse(floors[0].hasPlan)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }
}
