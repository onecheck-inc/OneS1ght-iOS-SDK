//
//  OneS1ghtTests.swift
//  OneS1ght 파사드(정적 진입점) 자체를 검증한다 — 버전 문자열 형식과, 콘솔 제공 값
//  접근자가 실제로 coordinator 까지 왕복하는지.
//

import XCTest
@testable import OneS1ght

final class OneS1ghtTests: XCTestCase {

    /// 버전 형식만 본다. 값을 여기 박아 두면 판올림마다 이 테스트가 깨지는데,
    /// 그때 사람은 "버전을 올렸으니 당연하지" 하고 숫자만 고친다 — 검사가 아니라 잡일이 된다.
    /// (실제로 0.1.1 판올림 때 여기가 깨진 채로 머지됐다.)
    ///
    /// 값이 맞는지는 다른 곳이 지킨다.
    ///  · SnippetsTests   — Snippets/ios.json 의 sdkVersion 과 일치하는가
    ///  · MigrationsTests — Migrations/ios.json 의 currentVersion 과 일치하는가
    ///  · Scripts/release.sh — 태그 번호 · CHANGELOG 항목과 일치하는가
    func testSdkVersionIsSemver() {
        let v = OneS1ght.sdkVersion
        XCTAssertFalse(v.isEmpty)
        XCTAssertNotNil(v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
                        "버전이 x.y.z 형식이 아니다: \(v)")
    }
}

/// `OneS1ght.googleMapKey` — 콘솔이 내려준 값 중 **호스트 앱이 직접 쓰는 유일한 값**이
/// 파사드 밖으로 정확히 나오는지 검증한다. 나머지(측위 라이선스·공간 서비스 키·주소)는
/// SDK 내부에서만 쓰이므로 파사드에 없다.
///
/// ⚠️ `SdkConfigResolutionTests.testOtherKeysAreKept` 는 이 값을 이미 검증하는 것처럼
/// 보이지만, `SessionCoordinator` 를 직접 만들어 돌린다 — `OneS1ght` 파사드는 손도 안 댄다.
/// 콘솔이 내려주는 값이 전부 `String?` 라서 접근자가 엉뚱한 필드로 연결돼도(예:
/// googleMapKey 가 coordinator.spaceServiceKey 를 반환) 컴파일은 그대로 되고, 그
/// 코디네이터 테스트도 그대로 통과한다. 여기서 세 값을 서로 다르게 스텁해, 자리가
/// 바뀌면 반드시 실패하게 한다.
///
/// `OneS1ght.initialize` 는 baseURL 만 받고 URLSession 을 주입받지 않는다(내부적으로
/// `URLSession.shared` 를 쓴다) — 그래서 다른 테스트들처럼 `makeStubSession()` 을
/// `ApiClient` 에 직접 넣을 수 없다. 대신 `URLProtocol.registerClass` 로 `.shared` 자체를
/// 가로챈다. setUp/tearDown 으로 테스트 하나의 실행 구간에만 등록해 다른 테스트로 새지
/// 않게 한다.
@MainActor
final class OneS1ghtConsoleProvidedValuesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.reset()
    }

    /// ⚠️ `OneS1ght.reset()` 을 여기로 옮겼다 — 예전에는 두 테스트 바디의 **끝**에서만
    /// 불렀는데, 그 앞줄에서 단언이 던지면(예: `try await initialize` 실패) 건너뛰어
    /// 세션이 다음 테스트로 샜다. tearDown 은 테스트가 실패해도 항상 돈다.
    override func tearDown() async throws {
        await OneS1ght.reset()
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    /// verify 는 항상 통과시키고, /config 는 세 값을 서로 다르게 응답한다 —
    /// 값이 같으면 자리가 바뀌어도 단언이 통과해 버린다.
    private func stubDistinctConfigValues() {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            if path.hasSuffix("/config") {
                return (200, Data(#"""
                { "google_map_key": "AIza_facade", "geo_partner_key": "gpk_facade",
                  "geo_base_url": "https://geospace.facade.test" }
                """#.utf8))
            }
            return (200, Data("{}".utf8))
        }
    }

    /// initialize 를 부르기 전에는 nil — 트랩하지 않는다.
    func testValuesAreNilBeforeInitialize() async {
        await OneS1ght.reset()   // 다른 테스트가 남긴 세션 격리
        XCTAssertNil(OneS1ght.googleMapKey)
    }

    /// initialize 이후 값이 콘솔 응답과 정확히 일치해야 한다 — 파사드를 실제로 거쳐서
    /// 나온 값인지, 그리고 옆자리 키를 집어 오지 않는지 확인하는 자리다.
    func testValuesGoThroughTheFacadeAfterInitialize() async throws {
        await OneS1ght.reset()
        stubDistinctConfigValues()

        try await OneS1ght.initialize(sdkKey: "ock_facade_probe",
                                      baseURL: URL(string: "https://stub.test/api/sdk/v1")!)

        XCTAssertEqual(OneS1ght.googleMapKey, "AIza_facade")
        // 세션 정리는 tearDown 이 맡는다 — 여기서 또 부르면 assert 가 던졌을 때 건너뛴다.
    }

    /// reset() 이후에는 다시 nil 로 돌아가야 한다 — 값이 세션에 묶여 있고 전역 상수가
    /// 아님을 확인한다.
    func testValuesReturnToNilAfterReset() async throws {
        await OneS1ght.reset()
        stubDistinctConfigValues()
        try await OneS1ght.initialize(sdkKey: "ock_facade_probe2",
                                      baseURL: URL(string: "https://stub.test/api/sdk/v1")!)
        XCTAssertNotNil(OneS1ght.googleMapKey, "sanity: 초기화가 실제로 값을 채웠는지")

        await OneS1ght.reset()

        XCTAssertNil(OneS1ght.googleMapKey)
    }

    /// 고객이 손댈 수 없어야 하는 값들은 파사드에 **없다**. 없다는 사실은 컴파일로만
    /// 지켜지므로(접근자를 되살리면 이 테스트는 그대로 통과한다), 대신 "코디네이터는
    /// 갖고 있는데 파사드로는 안 나온다"를 값으로 확인한다.
    func testInternalOnlyValuesStayOffTheFacade() async throws {
        await OneS1ght.reset()
        stubDistinctConfigValues()

        try await OneS1ght.initialize(sdkKey: "ock_facade_probe3",
                                      baseURL: URL(string: "https://stub.test/api/sdk/v1")!)

        // 파사드로 나오는 단 하나의 값이 내부 전용 값을 집어 오면 안 된다.
        XCTAssertNotEqual(OneS1ght.googleMapKey, "gpk_facade")
        XCTAssertNotEqual(OneS1ght.googleMapKey, "https://geospace.facade.test")
    }
}
