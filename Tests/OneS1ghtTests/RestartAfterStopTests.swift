//
//  RestartAfterStopTests.swift
//  종료 직후의 재시작 — 그 사이에 낀 start 가 삼켜지지 않는가.
//
//  2026-09-10 실기기: 신호를 잃어 [측위 종료] 를 누르면 화면은 「로케이터를 찾는 중」이
//  되는데 실제로는 아무것도 찾지 않았다. 로케이터 범위 안으로 걸어 들어가도 영영
//  돌아오지 않고, 앱을 백그라운드로 내렸다 올려야만 살아났다.
//
//  원인은 순서였다. `stop()` 은 잔여 좌표를 서버로 flush 하느라 await 하고,
//  `isRunning = false` 는 그 왕복이 끝난 뒤에야 세운다(현장 로그 157ms). 그 창에 들어온
//  `start()` 는 `guard !isRunning` 에 걸려 **로그 한 줄 없이** 돌아갔다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class RestartAfterStopTests: XCTestCase {

    private var provider: MockPositioningProvider!
    private var identity: IdentityStore!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        provider = MockPositioningProvider()
        let defaults = UserDefaults(suiteName: "RestartAfterStopTests")!
        defaults.removePersistentDomain(forName: "RestartAfterStopTests")
        identity = IdentityStore(secure: InMemorySecureStore(), defaults: defaults)
    }

    /// 좌표 전송만 느리게 만든다 — `stop()` 이 실기기처럼 flush 에서 실제로 매달리게.
    /// (핸들러는 URLSession 스레드에서 돈다. main actor 는 그동안 비어 있어야 재현된다.)
    private func routeWithSlowFlush(uploadDelay: TimeInterval = 0.15) {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            if path.hasSuffix("/config") { return (200, Data("{}".utf8)) }
            if path.hasSuffix("/positioning/logs") {
                Thread.sleep(forTimeInterval: uploadDelay)
                return (200, Data(#"{ "accepted_count": 1 }"#.utf8))
            }
            return (200, Data("{}".utf8))
        }
    }

    private func makeStarted() async throws -> SessionCoordinator {
        let c = SessionCoordinator(api: ApiClient(apiKey: "test-key",
                                                  baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                                                  session: makeStubSession()),
                                   identity: identity,
                                   flushThreshold: 1000)   // 자동 전송에 안 걸리게
        try await c.prepare()
        c.identify(profileId: "pf_8a3c")
        try await c.start(provider: provider)
        return c
    }

    /// ⚠️ 이 테스트가 핵심이다 — 실기기에서 났던 그 순서 그대로다.
    ///
    /// 앱은 `stopTracking()` 안에서 종료를 Task 로 띄우고, 바로 다음 줄에서 새 탐색을
    /// 시작한다. 두 Task 가 같은 main actor 위에서 앞뒤로 붙어 돌기 때문에, 시작은
    /// 종료가 flush 에 매달려 있는 그 순간에 들어온다.
    func testStartDuringStopEndsUpRunning() async throws {
        routeWithSlowFlush()
        let c = try await makeStarted()
        // 보낼 좌표를 쌓아 둔다 — 버퍼가 비어 있으면 flush 가 왕복 없이 즉시 끝나 재현이 안 된다.
        provider.simulatePosition(Coordinates(x: 1, y: 2, z: 0), floorId: "F")

        let stopping = Task { @MainActor in await c.stop() }
        let starting = Task { @MainActor in try await c.start(provider: self.provider) }
        await stopping.value
        try await starting.value

        XCTAssertTrue(c.isRunning,
                      "종료 직후의 start 가 삼켜졌다 — 화면은 「찾는 중」인데 실제로는 아무것도 안 돈다")
        XCTAssertTrue(provider.isRunning, "코어까지 다시 떠야 좌표가 나온다")
    }

    /// 정지가 끝난 뒤의 start 는 당연히 뜬다(회귀 대조군).
    func testStartAfterStopCompletesRuns() async throws {
        routeWithSlowFlush()
        let c = try await makeStarted()
        provider.simulatePosition(Coordinates(x: 1, y: 2, z: 0), floorId: "F")

        await c.stop()
        XCTAssertFalse(c.isRunning)
        try await c.start(provider: provider)
        XCTAssertTrue(c.isRunning)
    }

    /// 종료를 두 번 불러도 한 번만 내려간다 — 뒤엣것은 앞엣것에 합류한다.
    func testConcurrentStopsCollapseIntoOne() async throws {
        routeWithSlowFlush()
        let c = try await makeStarted()
        provider.simulatePosition(Coordinates(x: 1, y: 2, z: 0), floorId: "F")

        async let a: Void = c.stop()
        async let b: Void = c.stop()
        _ = await (a, b)

        XCTAssertFalse(c.isRunning)
        let uploads = StubURLProtocol.requests.filter { $0.path.hasSuffix("/positioning/logs") }
        XCTAssertEqual(uploads.count, 1, "같은 잔여 좌표를 두 번 올렸다")
    }

    /// 이미 돌고 있는데 또 start 하면 멱등이다 — 다만 **말은 한다**.
    /// 예전에는 이 자리가 조용해서, 삼켜진 start 하나가 현장에서 안 보였다.
    func testRedundantStartIsIdempotent() async throws {
        routeWithSlowFlush()
        let c = try await makeStarted()
        let visitorBefore = c.visitorId
        try await c.start(provider: provider)
        XCTAssertTrue(c.isRunning)
        XCTAssertEqual(c.visitorId, visitorBefore, "멱등이어야 한다 — 방문이 새로 발급되면 안 된다")
    }
}
