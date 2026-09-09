//
//  SdkConfigFetchTests.swift
//  콘솔이 내려주는 관련 키 — 앱이 키를 심어 나르지 않게 하는 자리.
//

import XCTest
@testable import OneS1ght

@MainActor
final class SdkConfigFetchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func client() -> ApiClient {
        ApiClient(apiKey: "ock_sdk_x",
                  baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                  session: makeStubSession())
    }

    func testDecodesEveryKey() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            { "tenant_code": "acme",
              "google_map_key": "AIzaSyExample",
              "geo_sdk_key": "gsk_example",
              "geo_partner_key": "gpk_example",
              "geo_base_url": "https://geospace.geoplan.io" }
            """#.utf8))
        }

        let cfg = try await client().config()

        XCTAssertEqual(cfg.tenant_code, "acme")
        XCTAssertEqual(cfg.google_map_key, "AIzaSyExample")
        XCTAssertEqual(cfg.geo_sdk_key, "gsk_example")
        XCTAssertEqual(cfg.geo_partner_key, "gpk_example")
        XCTAssertEqual(cfg.geo_base_url, "https://geospace.geoplan.io")
    }

    /// 서버가 부분 실패로 null 을 내려도 디코드가 깨지면 안 된다 —
    /// 깨지면 키 하나 때문에 초기화가 통째로 실패한다(2026-08-21 과 같은 모양).
    func testNullKeysDecodeAsNil() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{ "tenant_code": "acme", "google_map_key": null }"#.utf8))
        }

        let cfg = try await client().config()

        XCTAssertEqual(cfg.tenant_code, "acme")
        XCTAssertNil(cfg.google_map_key)
        XCTAssertNil(cfg.geo_sdk_key, "빠진 필드도 nil 이어야 한다")
        XCTAssertNil(cfg.geo_partner_key)
    }

    /// 서버가 필드를 늘려도 디코드가 깨지지 않아야 한다.
    func testUnknownFieldsAreIgnored() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{ "tenant_code": "acme", "something_new": 42 }"#.utf8))
        }

        let cfg = try await client().config()
        XCTAssertEqual(cfg.tenant_code, "acme")
    }

    // GET 경로 + X-SDK-Key 헤더 — verify()의 pathHeaderBodyAndDecode 시험과 같은 확인을 config()에도.
    func testConfig_pathMethodAndSdkKeyHeader() async throws {
        var seen: String?
        StubURLProtocol.handler = { req in
            seen = req.value(forHTTPHeaderField: "X-SDK-Key")
            return (200, Data(#"{ "tenant_code": "acme" }"#.utf8))
        }

        _ = try await client().config()

        XCTAssertEqual(seen, "ock_sdk_x")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.path, "/api/sdk/v1/config")
        XCTAssertEqual(req.httpMethod, "GET")
    }
}
