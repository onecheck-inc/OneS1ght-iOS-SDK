//
//  ApiClientTests.swift
//  URLProtocol 스텁으로 실서버 없이: 경로·메서드·X-SDK-Key·바디 정확성 + 상태코드→에러 매핑
//

import XCTest
@testable import OneS1ght

final class ApiClientTests: XCTestCase {

    var client: ApiClient!

    override func setUp() {
        super.setUp()
        client = ApiClient(apiKey: "test-key",
                           baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                           session: makeStubSession())
        StubURLProtocol.reset()
    }

    // ① verify — POST 경로·키 헤더·바디, 응답 디코딩
    func testVerify_pathHeaderBodyAndDecode() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
        }
        let res = try await client.verify(ReqVerify(platform_name: "iOS", app_id: "com.x",
                                                    client: nil))
        XCTAssertTrue(res.valid)
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.path, "/api/sdk/v1/auth/verify")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-SDK-Key"), "test-key")
        let body = try JSONDecoder().decode(ReqVerify.self, from: XCTUnwrap(StubURLProtocol.lastBody))
        XCTAssertEqual(body.platform_name, "iOS")
    }

    // ② buildings — GET 경로
    func testBuildings_isGET() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{ "synced_at": "s", "buildings": [] }"#.utf8))
        }
        _ = try await client.buildings()
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sdk/v1/positioning/buildings")
    }

    // ③ floors 404 → notFound (정상 분기용 — detail 파싱 포함)
    func testFloor404_mapsToNotFound() async {
        StubURLProtocol.handler = { _ in (404, Data(#"{ "detail": "no zones" }"#.utf8)) }
        do {
            _ = try await client.floorConfig(floorId: "f-uuid")
            XCTFail("에러여야 함")
        } catch let e as ApiError {
            XCTAssertEqual(e, .notFound(detail: "no zones"))
        } catch { XCTFail("ApiError여야 함: \(error)") }
    }

    // 401 → invalidKey
    func test401_mapsToInvalidKey() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{ "detail": "bad key" }"#.utf8)) }
        do {
            _ = try await client.buildings()
            XCTFail("에러여야 함")
        } catch let e as ApiError {
            XCTAssertEqual(e, .invalidKey(detail: "bad key"))
        } catch { XCTFail("ApiError여야 함") }
    }

    // ④ zone event — 경로 + triggers 디코딩
    func testZoneEvent_pathAndTriggers() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            { "accepted": true, "event_id": "e1",
              "triggers": [ { "trigger_id": "a1", "type": "coupon", "payload": null } ] }
            """#.utf8))
        }
        let res = try await client.sendZoneEvent(
            ReqZoneEvent(user_id: "A", visitor_id: "V", floor_id: "F", zone_id: "Z",
                         status: .enter, occurred_at: "T", platform_name: "iOS"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sdk/v1/events/zone")
        XCTAssertEqual(res.triggers.first?.type, "coupon")
    }

    // ⑤ position logs — 경로 + 422 매핑
    func testPositionLogs_pathAnd422() async {
        StubURLProtocol.handler = { _ in (422, Data(#"{ "detail": "empty points" }"#.utf8)) }
        do {
            _ = try await client.sendPositionLogs(
                ReqPositionBulk(user_id: "A", visitor_id: "V", platform_name: "iOS", points: []))
            XCTFail("에러여야 함")
        } catch let e as ApiError {
            XCTAssertEqual(e, .unprocessable(detail: "empty points"))
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sdk/v1/positioning/logs")
        } catch { XCTFail("ApiError여야 함") }
    }
}
