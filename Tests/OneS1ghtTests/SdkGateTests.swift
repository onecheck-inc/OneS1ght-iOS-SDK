//
//  SdkGateTests.swift
//  기기 게이트 위치 검증 — initialize 는 기기를 보지 않고, begin() 이 유일한 차단점이다.
//
//  2026-08-26 이전에는 initialize 자체가 기기 게이트였고(시뮬레이터만 예외), 이 파일은
//  "시뮬레이터 예외가 살아있는가"를 검증했다. 이제 게이트를 initialize 에서 완전히 들어냈다 —
//  UWB 없는 기기(시뮬레이터 포함)에서도 initialize 가 통과해야 도면·존 조회가 열리고,
//  실제 측위 차단은 FloorSession.begin() 하나로 모인다.
//
//  시뮬레이터에 UWB 가 없다는 사실 자체는 그대로라, "기기 게이트 없는 initialize · begin() 이
//  막는다"는 새 계약을 검증하기에 시뮬레이터가 여전히 적합한 환경이다(실기기 자동화 불가).
//

#if os(iOS) && targetEnvironment(simulator)

import XCTest
@testable import OneS1ght

@MainActor
final class SdkGateTests: XCTestCase {

    /// initialize 는 더 이상 기기 게이트를 보지 않는다 — 시뮬레이터든 실기기든 동일.
    /// 가짜 키라 결국 실패하지만, 실패 사유가 기기 게이트(deviceNotSupported/osVersionTooLow)가
    /// 아니라 서버 쪽(invalidKey/network)이면 "게이트가 initialize 에서 빠졌다"는 증거다.
    func testInitializeNeverThrowsDeviceGate() async {
        await OneS1ght.reset()                      // 이전 테스트 세션 격리
        do {
            try await OneS1ght.initialize(sdkKey: "ock_gate_probe_invalid")
            // 성공할 리 없는 키 — 성공하면 서버가 아무 키나 받는다는 뜻이라 그것대로 실패
            XCTFail("가짜 키로 initialize 가 성공함 — verify 검증 확인 필요")
        } catch let e as SdkError {
            XCTAssertNotEqual(e, .deviceNotSupported, "기기 게이트가 initialize 에 남아 있음")
            XCTAssertNotEqual(e, .osVersionTooLow, "OS 게이트가 initialize 에 남아 있음")
        } catch {
            // ApiError.invalidKey·URLError 등 = 게이트 없이 곧장 네트워크까지 갔다는 증거 → 통과
        }
        await OneS1ght.reset()
    }

    /// 조회 API(deviceAvailability)는 여전히 정직해야 한다 — initialize 를 막지 않을 뿐,
    /// 앱이 사전 안내 UI 에 쓰는 값 자체는 그대로 사유를 보고해야 한다.
    /// (iOS 26 런타임 시뮬레이터 → osVersionTooLow · iOS 27+ 시뮬레이터 → deviceNotSupported(칩 없음))
    func testAvailabilityIsHonestOnSimulator() {
        XCTAssertNotEqual(OneS1ght.deviceAvailability, .available,
                          "시뮬레이터에 UWB 가 있을 수 없음 — 조회가 거짓말 중")
        XCTAssertFalse(OneS1ght.isDeviceAvailable)
    }

    /// 새 계약의 핵심 — 실제 차단 지점은 begin() 이다.
    /// initialize 가 (가짜 키로) 실패해도 coordinator 는 이미 만들어져 있어 floorSession() 은
    /// 열리고, UWB 없는 시뮬레이터에서 begin() 을 부르면 거기서 deviceNotSupported 로 막힌다.
    func testBeginIsTheOnlyDeviceGate() async throws {
        await OneS1ght.reset()
        try? await OneS1ght.initialize(sdkKey: "ock_gate_probe_invalid")   // 키는 실패해도 무방
        let session = try OneS1ght.floorSession()
        do {
            try await session.begin()
            XCTFail("시뮬레이터에 UWB 가 있을 수 없음 — begin() 이 통과함")
        } catch let e as SdkError {
            XCTAssertEqual(e, .deviceNotSupported, "실제 차단 지점은 begin() 이어야 한다")
        }
        await OneS1ght.reset()
    }
}

#endif
