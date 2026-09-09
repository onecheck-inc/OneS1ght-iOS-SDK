//
//  SdkConfigResolutionTests.swift
//  측위 키의 출처는 콘솔 하나뿐이다 — 앱이 넘기는 경로가 없으므로 폴백도 없다.
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

    private func prepared() async throws -> (SessionCoordinator, [String]) {
        let api = ApiClient(apiKey: "ock_sdk_x",
                            baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                            session: makeStubSession())
        let c = SessionCoordinator(api: api, identity: identity, session: makeStubSession())
        var lines: [String] = []
        c.onLog = { _, line in lines.append(line) }
        try await c.prepare()
        return (c, lines)
    }

    /// 기본 경로 — 앱은 SDK 키 하나만 넘기고 측위 키는 콘솔에서 온다.
    func testConsoleSuppliesTheLicense() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "gsk_console" }"#)

        let (c, _) = try await prepared()

        XCTAssertEqual(c.positioningLicense, "gsk_console")
        XCTAssertTrue(c.isPrepared)
        XCTAssertFalse(c.keyResolutionFailed)
    }

    /// ⚠️ 어떤 로그에도 키 값이 실리면 안 된다.
    func testKeysNeverAppearInLogs() async throws {
        stub(configStatus: 200, configBody: #"""
        { "geo_sdk_key": "gsk_console", "google_map_key": "AIza1", "geo_partner_key": "gpk_1" }
        """#)

        let (_, lines) = try await prepared()

        XCTAssertFalse(lines.contains { $0.contains("gsk_console") || $0.contains("AIza1") || $0.contains("gpk_1") },
                       "키가 로그에 샜다: \(lines)")
    }

    /// 서버가 잠깐 흔들려도 초기화 자체는 성공해야 한다 — 앱 전체가 못 뜨면 안 된다.
    /// 대신 재시도 대상이라는 표시(keyResolutionFailed)를 남긴다.
    func testConfigFailureDoesNotBlockInitialization() async throws {
        stub(configStatus: 500, configBody: #"{ "detail": "boom" }"#)

        let (c, _) = try await prepared()

        XCTAssertTrue(c.isPrepared, "초기화 자체는 성공해야 한다")
        XCTAssertNil(c.positioningLicense)
        XCTAssertTrue(c.keyResolutionFailed, "통신 실패는 재시도로 풀릴 수 있다")
    }

    /// 응답은 왔는데 값이 비어 있으면 재시도해도 소용없다 — 콘솔 설정 문제다.
    /// 같은 응답을 계속 다시 물어보지 않도록 재시도 표시를 세우지 않는다.
    func testMissingKeyIsNotMarkedForRetry() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": null }"#)

        let (c, _) = try await prepared()

        XCTAssertNil(c.positioningLicense)
        XCTAssertTrue(c.isPrepared)
        XCTAssertFalse(c.keyResolutionFailed, "설정 부재는 재시도 대상이 아니다")
    }

    /// 빈 문자열도 "없음"이다 — 안 그러면 빈 라이선스가 엔진까지 내려간다.
    func testEmptyKeyCountsAsMissing() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": "" }"#)

        let (c, _) = try await prepared()

        XCTAssertNil(c.positioningLicense)
    }

    func testOtherKeysAreKept() async throws {
        stub(configStatus: 200, configBody: #"""
        { "google_map_key": "AIza1", "geo_partner_key": "gpk_1",
          "geo_base_url": "https://geospace.geoplan.io" }
        """#)

        let (c, _) = try await prepared()

        XCTAssertEqual(c.googleMapKey, "AIza1")
        XCTAssertEqual(c.spaceServiceKey, "gpk_1")
        XCTAssertEqual(c.spaceServiceBaseUrl, "https://geospace.geoplan.io")
    }

    // MARK: - I2: 경고가 report() 채널(콘솔 로그 분석기)에도 남는가
    //
    // onDebugLog(onLog) 만으로는 앱이 훅을 등록해야만 보인다 — OneS1ght.swift 는 그 훅을
    // "운영에선 미등록 권장"이라 문서화한다. report() 는 onLog 에도 "[E코드] 요약 — 문맥"
    // 형태의 줄을 남기고 logBuffer(콘솔로 나가는 채널)에도 같은 코드를 적재한다 — 그 줄이
    // 찍히는지 확인하면 report() 가 실제로 불렸는지(=logBuffer 로도 갔는지) 알 수 있다.
    // logBuffer.entries 를 직접 들여다보지 않는 이유 — ERROR 는 add() 가 즉시 flush 를
    // 스케줄링해서 나중에 비워질 수 있어(전송 성공 여부와 무관하게 먼저 뗀다), 그 시점을
    // 테스트가 관찰하려 들면 레이스가 된다. onLog 줄은 report() 안에서 동기로 남는다.

    /// 폴백이 없으므로 키를 못 받은 것은 곧 이번 세션 내내 측위·공간 조회가 죽었다는
    /// 뜻이다. 그런데 증상은 조용하다 — E1007 이 반드시 report() 채널로 남아야 한다.
    func testKeyUnavailableReachesReportChannelWhenConsoleHasNone() async throws {
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": null }"#)

        let (_, lines) = try await prepared()

        XCTAssertTrue(lines.contains { $0.hasPrefix("[\(SdkErrorCode.keyUnavailable.rawValue)]") }, "\(lines)")
    }

    func testKeyUnavailableReachesReportChannelWhenConfigFails() async throws {
        stub(configStatus: 500, configBody: #"{ "detail": "boom" }"#)

        let (_, lines) = try await prepared()

        XCTAssertTrue(lines.contains { $0.hasPrefix("[\(SdkErrorCode.keyUnavailable.rawValue)]") }, "\(lines)")
    }

    /// 원인은 로그에서 구분돼야 한다 — 통신 실패와 미설정은 대응이 다르다(재시도 vs 콘솔 설정).
    func testUnavailableReasonDistinguishesCause() async throws {
        stub(configStatus: 500, configBody: #"{ "detail": "boom" }"#)
        let (_, failLines) = try await prepared()

        StubURLProtocol.reset()
        stub(configStatus: 200, configBody: #"{ "geo_sdk_key": null }"#)
        let (_, emptyLines) = try await prepared()

        XCTAssertTrue(failLines.contains { $0.contains("reason=config_failed") }, "\(failLines)")
        XCTAssertTrue(emptyLines.contains { $0.contains("reason=console_no_key") }, "\(emptyLines)")
    }

    // MARK: - I3: 콘솔 키로 만든 SpaceServiceClient 도 주입된 세션을 물려받는가
    //
    // 만들기 전에는 문제가 드러나지 않는다 — 이 라운드 전까지는 그 뒤로 실제 조회가
    // 이어지는 테스트가 없었기 때문이다. buildings() 를 실제로 호출해, 응답이 스텁에서
    // 오는지(= 주입된 세션을 물려받았는지) 확인한다. 세션을 안 물려주면 `.shared` 로
    // 떨어져 실제 서비스로 나가려다 이 샌드박스에서는 실패/타임아웃한다.
    func testCreatedSpaceServiceClientUsesInjectedSession() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            if path.hasSuffix("/config") {
                return (200, Data(#"{ "geo_sdk_key": "gsk_console" }"#.utf8))
            }
            if path.hasSuffix("/positioning/buildings") {
                // 빈 배열이면 loadBuildings() 가 공간 서비스 직행으로 폴백한다(콘솔 미러가
                // 비었을 때의 정상 동작) — 이 테스트가 보려는 건 그 분기가 아니라 "콘솔 요청
                // 자체가 스텁 세션을 탔는가"이므로, 폴백을 안 타게 값을 하나 채운다.
                return (200, Data(#"{ "buildings": [ { "building_id": "B1", "name": "Test" } ] }"#.utf8))
            }
            return (200, Data("{}".utf8))
        }
        let api = ApiClient(apiKey: "ock_sdk_x",
                            baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                            session: makeStubSession())
        let c = SessionCoordinator(api: api, identity: identity, session: makeStubSession())
        try await c.prepare()

        let buildings = try await c.buildings()

        XCTAssertEqual(buildings.map(\.id), ["B1"])
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.path.hasSuffix("/positioning/buildings") },
                      "만들어진 SpaceServiceClient 가 스텁 세션을 타지 않았다 — session 주입이 안 됐다")
    }
}
