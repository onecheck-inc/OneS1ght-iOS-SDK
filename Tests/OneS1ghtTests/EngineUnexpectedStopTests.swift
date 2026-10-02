//
//  EngineUnexpectedStopTests.swift
//  엔진이 스스로 꺼졌을 때 — 세션이 "측위 중" 인 채 굳지 않는가.
//
//  2026-10-02 온보딩 앱: 백그라운드에서 돌아오면 코어가 엔진을 다시 켜는데, 그 시작이 접혀도
//  코어는 몰랐다. 세션은 "측위 중" 으로 남아 앱의 begin() 이 「이미 측위 중」 으로 삼켜졌고,
//  화면은 「찾는 중」인데 아무것도 안 도는 상태가 앱을 강제 종료할 때까지 갔다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class EngineUnexpectedStopTests: XCTestCase {

    private var provider: MockPositioningProvider!
    private var identity: IdentityStore!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            if path.hasSuffix("/positioning/logs") { return (200, Data(#"{ "accepted_count": 1 }"#.utf8)) }
            return (200, Data("{}".utf8))
        }
        provider = MockPositioningProvider()
        let defaults = UserDefaults(suiteName: "EngineUnexpectedStopTests")!
        defaults.removePersistentDomain(forName: "EngineUnexpectedStopTests")
        identity = IdentityStore(secure: InMemorySecureStore(), defaults: defaults)
    }

    /// 재시도 간격은 짧게 — 0.05초씩 두 번.
    private func makeStarted(delays: [TimeInterval] = [0.05, 0.05]) async throws -> SessionCoordinator {
        let c = SessionCoordinator(api: ApiClient(apiKey: "test-key",
                                                  baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                                                  session: makeStubSession()),
                                   identity: identity,
                                   flushThreshold: 1000,
                                   engineRestartDelays: delays)
        try await c.prepare()
        c.identify(profileId: "pf_8a3c")
        try await c.start(provider: provider)
        return c
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 다시 켜 볼 만하면 다시 켠다 — 세션은 그대로.
    func testRetryableStopRestartsEngine() async throws {
        let c = try await makeStarted()
        XCTAssertEqual(provider.startCount, 1)

        provider.simulateUnexpectedStop(retryable: true)
        await wait(0.2)

        XCTAssertEqual(provider.startCount, 2, "엔진을 다시 켜야 한다")
        XCTAssertTrue(provider.isRunning)
        XCTAssertTrue(c.isRunning, "다시 켜는 동안 세션은 닫지 않는다")
    }

    /// 재시도를 다 써도 안 되면 세션을 닫는다 — 그래야 앱의 begin() 이 다시 먹는다.
    func testGivesUpAfterAllRetriesAndClosesSession() async throws {
        let c = try await makeStarted(delays: [0.02])
        provider.simulateUnexpectedStop(retryable: true)    // 1회 재시도
        await wait(0.1)
        XCTAssertEqual(provider.startCount, 2)
        provider.simulateUnexpectedStop(retryable: true)    // 재시도 소진 → 닫음
        await wait(0.2)

        XCTAssertFalse(c.isRunning, "죽은 엔진 위에 세션을 「측위 중」 으로 남기면 begin() 이 삼켜진다")
        try await c.start(provider: provider)
        XCTAssertTrue(c.isRunning, "닫은 뒤의 begin() 은 다시 떠야 한다")
    }

    /// 사람이 풀어야 하는 것(권한·Bluetooth·라이선스)은 다시 켜 보지 않고 바로 닫는다.
    func testNonRetryableStopClosesSessionWithoutRetry() async throws {
        let c = try await makeStarted()
        provider.simulateUnexpectedStop(retryable: false)
        await wait(0.2)

        XCTAssertEqual(provider.startCount, 1, "권한 거부를 다시 켜 봐야 같은 자리에서 접힌다")
        XCTAssertFalse(c.isRunning)
    }

    /// 좌표가 한 번 나오면 재시도 횟수는 처음부터 — 한참 잘 돌다 난 고장에 남은 기회가 없으면 안 된다.
    func testPositionResetsRetryBudget() async throws {
        let c = try await makeStarted(delays: [0.02])
        provider.simulateUnexpectedStop(retryable: true)
        await wait(0.1)
        provider.simulatePosition(Coordinates(x: 1, y: 2, z: 0), floorId: "F")   // 살아났다
        provider.simulateUnexpectedStop(retryable: true)
        await wait(0.1)

        XCTAssertEqual(provider.startCount, 3, "살아난 뒤의 고장도 다시 켜 봐야 한다")
        XCTAssertTrue(c.isRunning)
    }

    /// 코어가 끈 뒤에 온 알림은 무시한다 — 닫힌 세션을 다시 켜면 안 된다.
    func testStopNoticeAfterEndIsIgnored() async throws {
        let c = try await makeStarted()
        await c.stop()
        provider.simulateUnexpectedStop(retryable: true)
        await wait(0.2)

        XCTAssertEqual(provider.startCount, 1)
        XCTAssertFalse(c.isRunning)
    }
}
