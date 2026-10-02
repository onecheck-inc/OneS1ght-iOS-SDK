//
//  TestSupport.swift
//  테스트 공용 준비 코드 — 코디네이터·스텁 응답·조건 대기.
//
//  예전엔 파일마다 같은 verify 응답·stub URL·IdentityStore·makeStarted 를 복사해 두었고, 0.1~0.8초
//  고정 대기로 결과를 봤다(2026-10-02 감사 K16). 느린 CI 에서 흔들리고, 준비 코드가 한 곳만 바뀌면
//  어긋났다. 여기 한 벌만 둔다 — 결과는 `waitUntil` 로 조건이 설 때까지 기다린다.
//

import XCTest
@testable import OneS1ght

/// 비동기 조건 폴링 — 조건이 서면 바로 돌아오고, `timeout` 안에 안 서면 실패로 남긴다.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ message: String = "조건 미충족",
               file: StaticString = #filePath, line: UInt = #line,
               _ cond: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    if !cond() { XCTFail("\(message) (\(timeout)초)", file: file, line: line) }
}

/// "일어나지 않아야 하는 일" 을 확인할 때 — 대기 중인 작업이 돌 틈을 준다.
/// 고정 대기가 남는 유일한 자리다: 일어나지 않음은 조건으로 기다릴 수 없다.
@MainActor
func settle(_ seconds: TimeInterval = 0.05) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
enum Fixture {

    static let baseURL = URL(string: "https://stub.test/api/sdk/v1")!

    static let verifyOK = #"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#

    /// 테스트마다 비운 UserDefaults 로 IdentityStore 를 만든다 — 방문 카운터가 테스트끼리 섞이지 않게.
    static func identity(_ suite: String) -> IdentityStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return IdentityStore(defaults: defaults)
    }

    static func api(key: String = "test-key") -> ApiClient {
        ApiClient(apiKey: key, baseURL: baseURL, session: makeStubSession())
    }

    static func coordinator(suite: String = #function,
                            flushThreshold: Int = 1000,
                            flushInterval: TimeInterval = 60,
                            receptionCheckDelay: TimeInterval = 7,
                            engineRestartDelays: [TimeInterval] = [3, 10, 30]) -> SessionCoordinator {
        SessionCoordinator(api: api(), identity: identity("Fixture.\(suite)"),
                           session: makeStubSession(),
                           flushThreshold: flushThreshold, flushInterval: flushInterval,
                           receptionCheckDelay: receptionCheckDelay,
                           engineRestartDelays: engineRestartDelays)
    }

    /// prepare → identify → start 까지.
    static func started(_ provider: PositioningProvider,
                        suite: String = #function,
                        flushThreshold: Int = 1000,
                        receptionCheckDelay: TimeInterval = 7,
                        engineRestartDelays: [TimeInterval] = [3, 10, 30]) async throws -> SessionCoordinator {
        let c = coordinator(suite: suite, flushThreshold: flushThreshold,
                            receptionCheckDelay: receptionCheckDelay,
                            engineRestartDelays: engineRestartDelays)
        try await c.prepare()
        c.identify(profileId: "pf_8a3c")
        try await c.start(provider: provider)
        return c
    }

    /// 경로 끝(suffix)으로 응답을 고른다. 없으면 `fallback`.
    /// verify 는 따로 안 적어도 통과한다 — 거의 모든 테스트의 전제다.
    static func route(_ routes: [String: (Int, String)] = [:],
                      fallback: (Int, String) = (200, "{}")) {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if let hit = routes.first(where: { path.hasSuffix($0.key) }) {
                return (hit.value.0, Data(hit.value.1.utf8))
            }
            if path.hasSuffix("/auth/verify") { return (200, Data(verifyOK.utf8)) }
            return (fallback.0, Data(fallback.1.utf8))
        }
    }

    static func requests(endingWith suffix: String) -> [(path: String, method: String, body: Data?)] {
        StubURLProtocol.requests.filter { $0.path.hasSuffix(suffix) }
    }
}
