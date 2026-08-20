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

    /// ⚠️ 2026-08-21 운영 사고 재현 — 이미 배포된 앱의 initialize 가 전부 실패했다.
    ///
    /// 서버 remote_config 에 정수·불리언이 섞여 있는데 SDK 가 `[String: String]` 로 좁게 받아
    /// **응답 전체 디코드가 실패**했다. 정작 SDK 는 이 값을 저장만 하고 읽지도 않는다.
    /// 아래 JSON 은 그날 서버가 실제로 보낸 본문 그대로다.
    ///
    /// 기존 verify 테스트는 remote_config 가 없는 최소 응답을 써서 이 사고를 못 잡았다 —
    /// 서버가 실제로 보내는 모양으로 시험하지 않으면 시험한 것이 아니다.
    func testVerify_mixedTypeRemoteConfig_doesNotBreakInitialisation() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            {"valid":true,"tenant_code":"onecheck-internal","positioning_enabled":true,
             "position_rate_hz":4,
             "remote_config":{"environment":"production","logLevel":"INFO",
                              "dataCollectionInterval":30,"enableSpatialSensing":true,
                              "enableAiPrediction":false,"autoCrashReport":true,
                              "customPayload":"{}"}}
            """#.utf8))
        }
        let res = try await client.verify(ReqVerify(platform_name: "iOS", app_id: "com.x", client: nil))

        // 초기화를 가르는 값은 그대로 살아 있어야 한다.
        XCTAssertTrue(res.valid)
        XCTAssertTrue(res.positioning_enabled)
        XCTAssertEqual(res.tenant_code, "onecheck-internal")
        XCTAssertEqual(res.position_rate_hz, 4)

        // 섞인 값은 문자열로 접혀 들어온다.
        let cfg = try XCTUnwrap(res.remote_config)
        XCTAssertEqual(cfg["environment"], "production")
        XCTAssertEqual(cfg["logLevel"], "INFO")
        XCTAssertEqual(cfg["dataCollectionInterval"], "30")
        XCTAssertEqual(cfg["enableSpatialSensing"], "true")
        XCTAssertEqual(cfg["enableAiPrediction"], "false")
    }

    /// 설정 자루가 어떤 모양이든 초기화를 막지 않는다 — 서버가 뭘 넣을지 SDK 는 모른다.
    func testVerify_unreadableRemoteConfig_stillInitialises() async throws {
        for weird in [#""문자열""#, "123", "null", #"{"nested":{"a":1}}"#, #"["배열"]"#] {
            StubURLProtocol.handler = { _ in
                (200, Data(#"{"valid":true,"positioning_enabled":true,"remote_config":\#(weird)}"#.utf8))
            }
            let res = try await client.verify(ReqVerify(platform_name: "iOS", app_id: "com.x", client: nil))
            XCTAssertTrue(res.valid, "remote_config=\(weird) 때문에 초기화가 막혔다")
        }
    }

    /// 디코드가 정말 실패할 때는 **무엇을 못 읽었는지** 남아야 한다.
    /// "decoding" 넉 자만 뜨면 현장에서 원인을 좁힐 수 없다.
    func testDecodingFailure_carriesWhatWentWrong() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"tenant_code":"t"}"#.utf8))     // valid·positioning_enabled 없음
        }
        do {
            _ = try await client.verify(ReqVerify(platform_name: "iOS", app_id: "com.x", client: nil))
            XCTFail("디코드가 실패했어야 한다")
        } catch let e as ApiError {
            guard case .decoding(let detail) = e else { return XCTFail("decoding 이 아님: \(e)") }
            let d = detail ?? ""
            XCTAssertTrue(d.contains("ResVerify"), "어느 응답인지 없다: \(d)")
            XCTAssertTrue(d.contains("valid"), "어느 필드인지 없다: \(d)")
            XCTAssertTrue("\(e)".contains("응답 해석 실패"), "사람이 읽을 문장이 아니다: \(e)")
        } catch {
            XCTFail("ApiError 가 아님: \(error)")
        }
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
            ReqZoneEvent(profile_id: "A", visitor_id: "V", floor_id: "F", zone_id: "Z",
                         status: .enter, occurred_at: "T", platform_name: "iOS"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sdk/v1/events/zone")
        XCTAssertEqual(res.triggers.first?.type, "coupon")
    }

    // ⑤ position logs — 경로 + 422 매핑
    func testPositionLogs_pathAnd422() async {
        StubURLProtocol.handler = { _ in (422, Data(#"{ "detail": "empty points" }"#.utf8)) }
        do {
            _ = try await client.sendPositionLogs(
                ReqPositionBulk(profile_id: "A", visitor_id: "V", platform_name: "iOS", points: []))
            XCTFail("에러여야 함")
        } catch let e as ApiError {
            XCTAssertEqual(e, .unprocessable(detail: "empty points"))
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sdk/v1/positioning/logs")
        } catch { XCTFail("ApiError여야 함") }
    }
}
