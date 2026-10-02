//
//  UwbProviderStateTests.swift
//  내장 provider 의 상태 전이 — 엔진 없이 늦은 알림·정지 순서를 직접 밟는다(2026-10-02 감사 S3·S8·S22·S24).
//
//  ⚠️ iOS 27 미만에서는 건너뛴다(PositioningPauseTests 머리말과 같은 이유).
//

#if os(iOS)
import XCTest
@testable import OneS1ght

@available(iOS 27.0, *)
@MainActor
final class UwbProviderStateTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("iOS 27 미만 — UwbPositioningProvider 를 생성할 수 없다")
        }
    }

    /// S22 — 늦게 온 시작 알림이 「정지 중」을 덮지 않는다.
    func testLateStartedNoticeDoesNotOverwriteStopping() {
        let p = UwbPositioningProvider()
        p.phase = .stopping
        p.hubStarted()
        XCTAssertEqual(p.phase, .stopping)
    }

    /// S22 — 늦게 온 추적 시작 알림도 마찬가지 — 층을 잡은 것으로 치지 않는다.
    func testLateTrackingNoticeIsIgnoredWhileStopping() {
        let p = UwbPositioningProvider()
        var floors: [Int64?] = []
        p.onFloorDetected = { floors.append($0) }
        p.phase = .stopping
        p.trackingStarted(14)
        XCTAssertEqual(p.phase, .stopping)
        XCTAssertNil(p.detectedFloorId)
        XCTAssertTrue(floors.isEmpty)
    }

    /// S3 — 권한 창을 기다리는 동안(엔진을 아직 안 띄움) 멈추면 곧장 대기 상태로 — 「정지 중」 에 굳지 않는다.
    func testStopWhileWaitingForPermissionGoesIdle() {
        let p = UwbPositioningProvider()
        p.phase = .starting
        p.stopDetection()
        XCTAssertEqual(p.phase, .idle, "띄운 적 없는 엔진은 정지 완료 신호를 주지 않는다")
    }

    /// S8 — 구역 재적재 중에 끄면 정지 완료 뒤 다시 켜지 않는다.
    func testStopDuringGeofenceReloadDoesNotRestart() {
        let p = UwbPositioningProvider()
        p.phase = .searching
        p.reloadingGeofences = true
        p.stopDetection()
        XCTAssertFalse(p.reloadingGeofences)
        p.hubStopped()                       // 엔진의 정지 완료
        XCTAssertEqual(p.phase, .idle, "재적재로 읽혀 엔진이 다시 뜨면 안 된다")
    }

    /// S24 — 위치 권한 설명 문구가 없으면 권한 창을 기다리며 굳지 않고 그 자리에서 알린다.
    /// (테스트 번들 자신의 Info.plist 에는 그 문구가 없다 — 앱 번들 대신 끼운다.)
    func testMissingLocationUsageDescriptionAbortsStart() throws {
        let p = UwbPositioningProvider()
        p.infoBundle = Bundle(for: UwbProviderStateTests.self)
        guard !UwbPositioningProvider.hasUsageDescription(UwbPositioningProvider.locationUsageKey,
                                                          in: p.infoBundle) else {
            throw XCTSkip("이 번들에는 문구가 있다")
        }
        var engineErrors: [Int] = []
        p.onEngineError = { code, _ in engineErrors.append(code) }
        p.license = "test-license"
        p.startDetection()
        // 위치 권한이 이미 정해진 시뮬레이터면 이 경로를 안 탄다 — 그때는 확인할 것이 없다.
        if engineErrors.isEmpty, p.phase == .starting {
            p.stopDetection()
            throw XCTSkip("위치 권한이 이미 정해져 있다")
        }
        XCTAssertEqual(p.phase, .idle)
        XCTAssertEqual(engineErrors.first, 7)
    }
}

/// S2 — 라이선스는 키를 다시 받은 **뒤에** 넣고, 그래도 비었으면 시작하지 않는다.
@available(iOS 27.0, *)
@MainActor
final class UwbBeginLicenseTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        guard #available(iOS 27.0, *) else { throw XCTSkip("iOS 27 미만") }
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        await OneS1ght.reset()
    }

    override func tearDown() async throws {
        await OneS1ght.reset()
        OneS1ght.identify(profileId: nil)
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    func testBeginWithoutLicenseThrowsInsteadOfStartingDeadEngine() async throws {
        Fixture.route(["/config": (500, "{}")])
        try await OneS1ght.initialize(sdkKey: "ock_no_license", baseURL: Fixture.baseURL)
        OneS1ght.identify(profileId: "pf")
        let provider = UwbPositioningProvider()
        do {
            try await OneS1ght.floorSession().begin(provider: provider)
            XCTFail("라이선스 없이 시작하면 세션은 「측위 중」, 엔진은 죽은 채로 남는다")
        } catch let e as SdkError {
            XCTAssertEqual(e, .notInitialized)
        }
        XCTAssertFalse(try OneS1ght.floorSession().isRunning)
    }

    /// 초기화 때 /config 가 실패했어도 begin 의 재시도가 성공하면 그 키로 시작한다(예전: 빈 라이선스).
    func testLicenseIsCopiedAfterKeyRetry() async throws {
        var configCalls = 0
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/auth/verify") { return (200, Data(Fixture.verifyOK.utf8)) }
            if path.hasSuffix("/config") {
                configCalls += 1
                return configCalls == 1 ? (500, Data()) : (200, Data(#"{ "geo_sdk_key": "gsk_retry" }"#.utf8))
            }
            return (200, Data("{}".utf8))
        }
        try await OneS1ght.initialize(sdkKey: "ock_retry_license", baseURL: Fixture.baseURL)
        OneS1ght.identify(profileId: "pf")
        let provider = UwbPositioningProvider()
        try? await OneS1ght.floorSession().begin(provider: provider)
        XCTAssertEqual(provider.license, "gsk_retry")
        try await OneS1ght.floorSession().end()
    }
}
#endif
