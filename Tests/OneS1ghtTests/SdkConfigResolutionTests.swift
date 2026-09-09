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

    /// geoSdkKey 인자가 없어지면 이 경로 — 앱은 키를 아예 안 넘기고 콘솔이 유일한
    /// 출처 — 가 모든 도입 앱의 기본 경로가 된다. `geospace` 가 nil 로 시작하는 채로
    /// 콘솔 키로 갈아끼워지는지, 여기서만 확인된다.
    ///
    /// 비교할 앱 값이 없으니 불일치 경고는 뜨지 않아야 한다 — 여기서 울리면 새 방식을
    /// 쓰는 모든 앱이 실행할 때마다 늑대가 왔다고 외치는 꼴이 된다.
    func testConsoleSuppliesKeyWhenAppProvidesNone() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "gsk_console" }"#)

        let (c, lines) = try await prepared(appKey: nil)

        XCTAssertEqual(c.resolvedGeoSdkKey, "gsk_console")
        XCTAssertTrue(c.isPrepared)
        XCTAssertFalse(lines.contains(SdkLocalized.text("coord.keyOverridden")), "\(lines)")
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
    ///
    /// ⚠️ 문구를 직접 쓰지 않고 i18n 에서 꺼내 대조한다 — 테스트가 도는 기기 언어에
    ///    따라 문구가 달라지므로, 한국어를 박아 두면 다른 언어 환경에서 헛되이 붉어진다.
    func testFallsBackToTheAppKeyWhenConfigFails() async throws {
        stub(configStatus: 500, configBody: #"{ "detail": "boom" }"#)

        let (c, lines) = try await prepared(appKey: "gsk_app")

        XCTAssertEqual(c.resolvedGeoSdkKey, "gsk_app")
        XCTAssertTrue(c.isPrepared, "초기화 자체는 성공해야 한다")
        let expected = SdkLocalized.text("coord.keyFallback")
        XCTAssertEqual(lines.filter { $0 == expected }.count, 1,
                       "폴백 사실을 정확히 한 번 알려야 한다: \(lines)")
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

    // MARK: - I2: 새 경고가 report() 채널(콘솔 로그 분석기)에도 남는가
    //
    // onDebugLog(onLog) 만으로는 앱이 훅을 등록해야만 보인다 — OneS1ght.swift 는 그 훅을
    // "운영에선 미등록 권장"이라 문서화한다. report() 는 onLog 에도 "[E코드] 요약 — 문맥"
    // 형태의 줄을 남기고 logBuffer(콘솔로 나가는 채널)에도 같은 코드를 적재한다 — 그 줄이
    // 찍히는지 확인하면 report() 가 실제로 불렸는지(=logBuffer 로도 갔는지) 알 수 있다.
    // logBuffer.entries 를 직접 들여다보지 않는 이유 — ERROR 는 add() 가 즉시 flush 를
    // 스케줄링해서 나중에 비워질 수 있어(전송 성공 여부와 무관하게 먼저 뗀다), 그 시점을
    // 테스트가 관찰하려 들면 레이스가 된다. onLog 줄은 report() 안에서 동기로 남는다.

    func testKeyOverriddenReachesReportChannel() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "gsk_console" }"#)

        let (_, lines) = try await prepared(appKey: "gsk_app")

        XCTAssertTrue(lines.contains { $0.hasPrefix("[\(SdkErrorCode.keyOverridden.rawValue)]") }, "\(lines)")
    }

    func testKeyFallbackReachesReportChannel() async throws {
        stub(configStatus: 500, configBody: #"{ "detail": "boom" }"#)

        let (_, lines) = try await prepared(appKey: "gsk_app")

        XCTAssertTrue(lines.contains { $0.hasPrefix("[\(SdkErrorCode.keyFallback.rawValue)]") }, "\(lines)")
    }

    /// 앱도 콘솔도 키가 없는 경우 — I1 이 지적한 가장 조용히 새던 자리. E1007 이 반드시
    /// report() 채널로 남아야 한다.
    func testKeyUnavailableReachesReportChannel() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": null }"#)

        let (_, lines) = try await prepared(appKey: nil)

        XCTAssertTrue(lines.contains { $0.hasPrefix("[\(SdkErrorCode.keyUnavailable.rawValue)]") }, "\(lines)")
    }

    // MARK: - I3: 콘솔 키로 갈아끼운 GeospaceClient 도 주입된 세션을 물려받는가
    //
    // 갈아끼우기 전에는 문제가 드러나지 않는다 — 이 라운드 전까지는 그 뒤로 실제 조회가
    // 이어지는 테스트가 없었기 때문이다. buildings() 를 실제로 호출해, 응답이 스텁에서
    // 오는지(= 주입된 세션을 물려받았는지) 확인한다. 세션을 안 물려주면 `.shared` 로
    // 떨어져 실제 geospace.geoplan.io 로 나가려다 이 샌드박스에서는 실패/타임아웃한다.
    func testReplacedGeospaceClientUsesInjectedSession() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            if path.hasSuffix("/config") {
                return (200, Data(#"{ "geo_sdk_key": "gsk_console" }"#.utf8))
            }
            if path.hasSuffix("/positioning/buildings") {
                // 빈 배열이면 loadBuildings() 가 GeoSpace 직행(api/m/buildings)으로 폴백한다
                // (콘솔 미러가 비었을 때의 정상 동작) — 이 테스트가 보려는 건 그 분기가 아니라
                // "콘솔 요청 자체가 스텁 세션을 탔는가"이므로, 폴백을 안 타게 값을 하나 채운다.
                return (200, Data(#"{ "buildings": [ { "building_id": "B1", "name": "Test" } ] }"#.utf8))
            }
            return (200, Data("{}".utf8))
        }
        let api = ApiClient(apiKey: "ock_sdk_x",
                            baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                            session: makeStubSession())
        // geospace: nil — appKey 를 안 넘긴 기본경로. resolveKeysFromConsole() 이 콘솔 키로
        // 새 GeospaceClient 를 "만드는" 자리를 검증해야 하므로 미리 만들어 두지 않는다.
        let c = SessionCoordinator(api: api, identity: identity, session: makeStubSession())
        try await c.prepare()

        let buildings = try await c.buildings()

        XCTAssertEqual(buildings.map(\.id), ["B1"])
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.path.hasSuffix("/positioning/buildings") },
                      "갈아끼운 GeospaceClient 가 스텁 세션을 타지 않았다 — session 주입이 안 됐다")
    }
}
