//
//  SdkGateTests.swift
//  initialize 기기 게이트 검증 — 시뮬레이터 예외가 실제로 동작하는가.
//
//  시뮬레이터는 UWB 칩이 없어 deviceAvailability == .deviceNotSupported 이지만,
//  initialize 의 게이트는 #if !targetEnvironment(simulator) 라 통과해야 한다.
//  (통과 증거 = 실패하더라도 그 사유가 기기 게이트가 아닌 네트워크/키 쪽이어야 함)
//

#if os(iOS) && targetEnvironment(simulator)

import XCTest
@testable import OneS1ght

@MainActor
final class SdkGateTests: XCTestCase {

    /// 시뮬레이터에서 initialize 는 기기 게이트에 막히면 안 된다.
    /// 가짜 키라 결국 실패하지만, 실패 사유가 게이트(deviceNotSupported/osVersionTooLow)가
    /// 아니라 서버 쪽(invalidKey/network)이면 게이트를 통과했다는 증거다.
    func testInitializeGateExemptOnSimulator() async {
        await OneS1ght.reset()                      // 이전 테스트 세션 격리
        do {
            try await OneS1ght.initialize(sdkKey: "ock_gate_probe_invalid")
            // 성공할 리 없는 키 — 성공하면 서버가 아무 키나 받는다는 뜻이라 그것대로 실패
            XCTFail("가짜 키로 initialize 가 성공함 — verify 검증 확인 필요")
        } catch let e as SdkError {
            XCTAssertNotEqual(e, .deviceNotSupported, "시뮬레이터 예외가 깨짐 — 기기 게이트에 막힘")
            XCTAssertNotEqual(e, .osVersionTooLow, "시뮬레이터 예외가 깨짐 — OS 게이트에 막힘")
        } catch {
            // ApiError.invalidKey·URLError 등 = 게이트를 지나 네트워크까지 갔다는 증거 → 통과
        }
        await OneS1ght.reset()
    }

    /// 조회 API 는 시뮬레이터에서도 정직해야 한다 — 사유는 런타임에 따라 다르되 available 은 아니어야 함.
    /// (iOS 26 런타임 시뮬레이터 → osVersionTooLow · iOS 27+ 시뮬레이터 → deviceNotSupported(칩 없음))
    func testAvailabilityIsHonestOnSimulator() {
        XCTAssertNotEqual(OneS1ght.deviceAvailability, .available,
                          "시뮬레이터에 UWB 가 있을 수 없음 — 조회가 거짓말 중")
        XCTAssertFalse(OneS1ght.isDeviceAvailable)
    }
}

#endif
