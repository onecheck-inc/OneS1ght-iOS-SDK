//
//  ReceptionCheckTests.swift
//  로케이터 수신 진단 — 무엇을 알리고, 무엇을 알리지 않는가.
//
//  여기서 지키는 것은 **알리는 세기**다. 앵커 세트는 마스터 1대와 서브 여러 대로 이루어지고,
//  마스터가 살아 있는 한 서브가 빠져도 측위는 계속된다 — 감도가 떨어질 뿐이다.
//  그런 상태를 ERROR 로 올리면 멀쩡한 현장에서 계속 울려, 정작 진짜 문제가 났을 때 아무도 안 본다.
//  그렇다고 침묵하면 로케이터가 죽은 채로 몇 달이 간다. 그래서 WARN 이다.
//

import XCTest
@testable import OneS1ght

/// 진단을 낼 수 있는 provider. 값은 테스트가 정한다.
@MainActor
final class DiagnosticProvider: PositioningProvider {
    weak var delegate: PositioningProviderDelegate?
    var diagnostic: PositioningDiagnostic?

    init(diagnostic: PositioningDiagnostic?) { self.diagnostic = diagnostic }

    var positioningDiagnostic: PositioningDiagnostic? { diagnostic }
    func start() {}
    func stop() {}
}

@MainActor
final class ReceptionCheckTests: XCTestCase {

    private var identity: IdentityStore!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        // 이 테스트가 보는 것은 진단 판정뿐이라, 서버는 무엇을 물어도 통과시킨다.
        StubURLProtocol.handler = { req in
            if (req.url?.path ?? "").hasSuffix("/auth/verify") {
                return (200, Data(#"{ "valid": true, "tenant_code": "t", "positioning_enabled": true }"#.utf8))
            }
            return (200, Data(#"{ "accepted_count": 0 }"#.utf8))
        }
        let defaults = UserDefaults(suiteName: "ReceptionCheckTests")!
        defaults.removePersistentDomain(forName: "ReceptionCheckTests")
        identity = IdentityStore(secure: InMemorySecureStore(), defaults: defaults)
    }

    /// 진단을 붙인 채 측위를 켜고, 확인이 돌 때까지 기다린 뒤 남은 로그를 돌려준다.
    private func runCheck(_ diagnostic: PositioningDiagnostic?) async throws -> [String] {
        let c = SessionCoordinator(api: ApiClient(apiKey: "test-key",
                                                  baseURL: URL(string: "https://stub.test/api/sdk/v1")!,
                                                  session: makeStubSession()),
                                   identity: identity,
                                   receptionCheckDelay: 0.05)
        var lines: [String] = []
        c.onLog = { lines.append($0) }

        try await c.prepare()
        c.identify(profileId: "pf_8a3c")
        try await c.start(provider: DiagnosticProvider(diagnostic: diagnostic))

        try await Task.sleep(nanoseconds: 250_000_000)
        return lines
    }

    private func hasCode(_ lines: [String], _ code: String) -> Bool {
        lines.contains { $0.contains("[\(code)]") }
    }

    /**
     * ⚠️ 서브가 빠진 상태는 **알리되 막지 않는다.**
     * 마스터가 살아 있으면 측위는 계속되므로 고장이 아니라 유지보수 신호다.
     */
    func testMissingLocatorIsReportedAsWarning() async throws {
        let lines = try await runCheck(PositioningDiagnostic(
            registeredCount: 4, receivedCount: 3, matchedCount: 3,
            missingAddresses: [0x9DD7], hasFix: true))

        XCTAssertTrue(hasCode(lines, "E4003"), "미수신을 알려야 유지보수가 시작된다: \(lines)")
        XCTAssertEqual(SdkErrorCode.locatorNotReceived.level, .warn,
                       "측위가 계속되는 상태라 ERROR 가 아니다")
    }

    /// 어느 주소가 빠졌는지 로그에 남아야 한다 — 현장에서 기기 라벨과 대조할 값이다.
    func testMissingAddressAppearsInTheLog() async throws {
        let lines = try await runCheck(PositioningDiagnostic(
            registeredCount: 4, receivedCount: 3, matchedCount: 3,
            missingAddresses: [0x9DD7], hasFix: true))

        XCTAssertTrue(lines.contains { $0.contains("0x9DD7") }, "\(lines)")
    }

    /// 다 잡히고 좌표도 나오면 아무 말도 하지 않는다. 조용한 것이 정상이다.
    func testHealthySessionSaysNothing() async throws {
        let lines = try await runCheck(PositioningDiagnostic(
            registeredCount: 4, receivedCount: 4, matchedCount: 4,
            missingAddresses: [], hasFix: true))

        XCTAssertFalse(hasCode(lines, "E4003"), "\(lines)")
        XCTAssertFalse(hasCode(lines, "E4002"), "\(lines)")
    }

    /**
     * 신호는 충분히 잡히는데 좌표가 안 나오는 것은 다른 이야기다 —
     * 등록 좌표와 실제 배치가 어긋났을 가능성이 크고, 측위가 실제로 막혀 있다. 그래서 ERROR.
     */
    func testSignalWithoutFixIsAnError() async throws {
        let lines = try await runCheck(PositioningDiagnostic(
            registeredCount: 4, receivedCount: 4, matchedCount: 4,
            missingAddresses: [], hasFix: false))

        XCTAssertTrue(hasCode(lines, "E4002"), "\(lines)")
        XCTAssertEqual(SdkErrorCode.noPositionFix.level, .error)
    }

    /// 잡힌 것이 3대 미만이면 좌표가 안 나오는 게 당연하다 — 배치 불일치로 몰지 않는다.
    func testTooFewLocatorsIsNotReportedAsPlacementProblem() async throws {
        let lines = try await runCheck(PositioningDiagnostic(
            registeredCount: 4, receivedCount: 2, matchedCount: 2,
            missingAddresses: [0x0001, 0x0002], hasFix: false))

        XCTAssertTrue(hasCode(lines, "E4003"), "미수신은 알린다: \(lines)")
        XCTAssertFalse(hasCode(lines, "E4002"), "원인이 다른데 배치 문제로 안내하면 헛수고를 시킨다: \(lines)")
    }

    /// 진단을 못 내는 provider(Mock 등)에서는 아무 말도 하지 않는다.
    func testProviderWithoutDiagnosticStaysQuiet() async throws {
        let lines = try await runCheck(nil)

        XCTAssertFalse(hasCode(lines, "E4003"), "\(lines)")
        XCTAssertFalse(hasCode(lines, "E4002"), "\(lines)")
    }
}
