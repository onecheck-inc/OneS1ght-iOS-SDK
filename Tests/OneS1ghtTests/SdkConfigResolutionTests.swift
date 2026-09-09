//
//  SdkConfigResolutionTests.swift
//  키의 정본은 콘솔이다 — 앱이 넘긴 값은 콘솔이 답하지 못할 때만 쓴다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class SdkConfigResolutionTests: XCTestCase {

    private var identity: IdentityStore!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let defaults = UserDefaults(suiteName: "SdkConfigResolutionTests")!
        defaults.removePersistentDomain(forName: "SdkConfigResolutionTests")
        identity = IdentityStore(secure: InMemorySecureStore(), defaults: defaults)
    }

    /// verify 는 늘 통과시키고, /config 응답만 테스트가 정한다.
    private func stub(configStatus: Int, configBody: String) {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            if path.hasSuffix("/config") {
                return (configStatus, Data(configBody.utf8))
            }
            return (200, Data("{}".utf8))
        }
    }

    private func prepared(appKey: String?) async throws -> (SessionCoordinator, [String]) {
        let api = ApiClient(apiKey: "ock_sdk_x",
                            baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                            session: makeStubSession())
        let geospace = appKey.map { GeospaceClient(keys: .init(sdk: "ock_sdk_x", geospace: $0)) }
        let c = SessionCoordinator(api: api, identity: identity, geospace: geospace)
        c.appProvidedGeoSdkKey = appKey
        var lines: [String] = []
        c.onLog = { _, line in lines.append(line) }
        try await c.prepare()
        return (c, lines)
    }

    func testConsoleValueWins() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "gsk_console" }"#)

        let (c, _) = try await prepared(appKey: "gsk_app")

        XCTAssertEqual(c.resolvedGeoSdkKey, "gsk_console", "정본은 콘솔이다")
    }

    /// 조용히 덮으면 "왜 다른 키로 붙지" 를 현장에서 파게 된다. 사실을 남긴다.
    ///
    /// ⚠️ 문구를 직접 쓰지 않고 i18n 에서 꺼내 대조한다 — 테스트가 도는 기기 언어에
    ///    따라 문구가 달라지므로, 한국어를 박아 두면 다른 언어 환경에서 헛되이 붉어진다.
    func testMismatchIsAnnouncedOnce() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "gsk_console" }"#)

        let (_, lines) = try await prepared(appKey: "gsk_app")

        let expected = SdkLocalized.text("coord.keyOverridden")
        XCTAssertEqual(lines.filter { $0 == expected }.count, 1,
                       "불일치를 정확히 한 번 알려야 한다: \(lines)")
    }

    /// 앱 값과 콘솔 값이 같으면 알릴 것이 없다 — 매번 울리면 진짜 불일치가 묻힌다.
    func testNoAnnouncementWhenTheyMatch() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "gsk_same" }"#)

        let (_, lines) = try await prepared(appKey: "gsk_same")

        XCTAssertFalse(lines.contains(SdkLocalized.text("coord.keyOverridden")), "\(lines)")
    }

    /// ⚠️ 어떤 로그에도 키 값이 실리면 안 된다.
    func testKeysNeverAppearInLogs() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "gsk_console" }"#)

        let (_, lines) = try await prepared(appKey: "gsk_app")

        XCTAssertFalse(lines.contains { $0.contains("gsk_console") || $0.contains("gsk_app") },
                       "키가 로그에 샜다: \(lines)")
    }

    /// 서버가 잠깐 흔들린다고 측위가 멈추면 안 된다.
    func testFallsBackToTheAppKeyWhenConfigFails() async throws {
        stub(configStatus: 500, configBody: #"{ "detail": "boom" }"#)

        let (c, lines) = try await prepared(appKey: "gsk_app")

        XCTAssertEqual(c.resolvedGeoSdkKey, "gsk_app")
        XCTAssertTrue(c.isPrepared, "초기화 자체는 성공해야 한다")
        XCTAssertFalse(lines.filter { $0.contains("폴백") }.isEmpty, "폴백 사실은 남긴다: \(lines)")
    }

    /// 콘솔에 값이 없는 것과 통신 실패는 다르지만, 앱 입장에서 할 일은 같다 — 폴백.
    func testFallsBackWhenConsoleHasNoKey() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": null }"#)

        let (c, _) = try await prepared(appKey: "gsk_app")

        XCTAssertEqual(c.resolvedGeoSdkKey, "gsk_app")
    }

    /// 앱도 안 넘기고 콘솔에도 없으면 측위만 비활성 — 초기화는 성공한다.
    func testNoKeyAnywhereStillInitializes() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": null }"#)

        let (c, _) = try await prepared(appKey: nil)

        XCTAssertNil(c.resolvedGeoSdkKey)
        XCTAssertTrue(c.isPrepared)
    }

    func testOtherKeysAreKept() async throws {
        stub(configStatus: 200, configBody: #"""
        { "google_map_key": "AIza1", "geo_partner_key": "gpk_1",
          "geo_base_url": "https://geospace.geoplan.io" }
        """#)

        let (c, _) = try await prepared(appKey: nil)

        XCTAssertEqual(c.googleMapKey, "AIza1")
        XCTAssertEqual(c.geoPartnerKey, "gpk_1")
        XCTAssertEqual(c.geoBaseUrl, "https://geospace.geoplan.io")
    }
}
