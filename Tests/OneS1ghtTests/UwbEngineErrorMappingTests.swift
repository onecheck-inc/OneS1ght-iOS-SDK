//
//  UwbEngineErrorMappingTests.swift
//  엔진 오류 코드(1~12) → SDK E-코드.
//
//  이 매핑이 있어야 엔진 고유의 실패가 콘솔 로그 분석기까지 간다. 화면 로그로만 남기면
//  현장에서만 보이고 관리자는 "안 됐다"는 말만 듣는다.
//
//  ⚠️ 전부 올리지는 않는다. 2(이미 측위 중)·8(정지 중 start)은 호출 순서 문제라
//     현장 진단 가치가 없고, 재시도마다 쌓여 진짜 오류를 덮는다.
//

#if os(iOS)

import XCTest
@testable import OneS1ght

@available(iOS 27.0, *)
final class UwbEngineErrorMappingTests: XCTestCase {

    private func code(_ hub: Int) -> SdkErrorCode? {
        UwbPositioningProvider.sdkCode(forHubError: hub)
    }

    /// Bluetooth 꺼짐은 권한 거부와 할 일이 달라(켜면 풀린다) E2004 로 따로 간다 — 엔진은 둘 다
    /// 오류 3 이고 메시지로만 갈린다(실기기 문장 그대로).
    func testBluetoothPoweredOffIsNotPermissionDenied() {
        XCTAssertEqual(UwbPositioningProvider.sdkCode(forHubError: 3,
                                                     message: "bluetooth unavailable: powered off"),
                       .bluetoothOff)
        XCTAssertEqual(UwbPositioningProvider.sdkCode(forHubError: 3, message: "unauthorized"),
                       .permissionDenied, "권한 쪽은 그대로 E2003")
    }

    /// 시작 단계에서 난 치명 오류는 엔진이 뜨지 못한 것이다 — onStopped 가 안 오므로 되돌려야 한다.
    /// 3·7·10 이 빠져 있어 Bluetooth 를 끈 채 시작하면 정지가 영영 안 끝나고 굳었다(2026-09-28).
    func testFatalErrorsDuringStartAbortTheStart() {
        for hub in [1, 3, 7, 9, 10, 11, 12] {
            XCTAssertTrue(UwbPositioningProvider.abortsStart(hubError: hub), "엔진 \(hub)")
        }
    }

    /// 호출 순서 문제(2·8)와 뜬 뒤의 오류(4·5·6)는 시작을 되돌리지 않는다.
    /// 스스로 멈춘 엔진을 코어가 다시 켜 볼 것인가 — 사람이 풀어야 하는 것(라이선스 없음·Bluetooth·
    /// 위치·라이선스 거부)은 아니다. 다시 켜 봐야 같은 자리에서 접힌다. 원인 모름(nil)·라이선스 서버
    /// 연결(11) 등은 잠시 뒤 풀릴 수 있어 다시 켠다(2026-10-02 복귀 재시작 실패).
    func testRetryableEngineStops() {
        for hub in [1, 3, 7, 10] {
            XCTAssertFalse(UwbPositioningProvider.isRetryable(hubError: hub), "엔진 \(hub)")
        }
        for hub in [2, 9, 11, 12] {
            XCTAssertTrue(UwbPositioningProvider.isRetryable(hubError: hub), "엔진 \(hub)")
        }
        XCTAssertTrue(UwbPositioningProvider.isRetryable(hubError: nil))
    }

    func testNonFatalErrorsDoNotAbortTheStart() {
        for hub in [2, 4, 5, 6, 8, 0, 13] {
            XCTAssertFalse(UwbPositioningProvider.abortsStart(hubError: hub), "엔진 \(hub)")
        }
    }

    /// 권한 계열 셋(BT 불가·위치 불가·Info.plist 키 누락)은 모두 E2003 이다 —
    /// 관리자가 할 일이 같다: 사용자에게 설정을 안내한다.
    func testPermissionFamilyMapsToPermissionDenied() {
        XCTAssertEqual(code(3), .permissionDenied)
        XCTAssertEqual(code(7), .permissionDenied)
        XCTAssertEqual(code(9), .permissionDenied)
        XCTAssertEqual(UwbPositioningProvider.sdkCode(forHubError: 3,
                                                     message: "bluetooth unavailable: permission required"),
                       .permissionDenied)
    }

    /// Bluetooth 미지원 기기는 권한 거부가 아니라 미지원 기기(E2002)다 — 설정 안내로는 안 풀린다
    /// (2026-10-03 안드 감사 SP-B9, 엔진 1.1.0 문장 그대로).
    func testBluetoothUnsupportedIsDeviceNotSupported() {
        XCTAssertEqual(UwbPositioningProvider.sdkCode(forHubError: 3,
                                                     message: "bluetooth unavailable: unsupported on this device"),
                       .deviceNotSupported)
    }

    /// 라이선스 계열은 측위 키(콘솔이 주는 엔진 라이선스) 문제다 — E1007. 예전엔 E1002(SDK 키 무효)라
    /// 멀쩡한 SDK 키를 의심하게 했다(2026-10-03 안드 감사 SP-B9).
    func testLicenseFamilyMapsToKeyUnavailable() {
        XCTAssertEqual(code(1),  .keyUnavailable, "라이선스 미등록")
        XCTAssertEqual(code(10), .keyUnavailable, "서버가 거부")
    }

    /// 라이선스가 비어 시작하지 못한 것도 콘솔까지 E1007 로 올라간다 — 예전엔 엔진 훅(onEngineError)만 불렀다.
    @MainActor
    func testEmptyLicenseReportsKeyUnavailable() {
        final class Spy: PositioningProviderDelegate {
            var codes: [SdkErrorCode] = []
            func provider(_ p: PositioningProvider, didUpdate coordinates: Coordinates, floorId: String, at: Date) {}
            func provider(_ p: PositioningProvider, didDetectZone zoneId: String, status: ZoneEventStatus,
                          floorId: String, at: Date) {}
            func provider(_ p: PositioningProvider, didReport code: SdkErrorCode, context: String) {
                codes.append(code)
            }
        }
        let p = UwbPositioningProvider()
        let spy = Spy()
        p.delegate = spy
        var engineErrors: [Int] = []
        p.onEngineError = { c, _ in engineErrors.append(c) }
        p.license = "  "
        p.startDetection()
        XCTAssertEqual(spy.codes, [.keyUnavailable])
        XCTAssertEqual(engineErrors, [1])
        XCTAssertEqual(p.phase, .idle)
    }

    /// 라이선스 서버에 못 닿은 것은 키 문제가 아니라 통신 문제다 — 재시도가 유효하다.
    func testUnreachableLicenseServerIsNetwork() {
        XCTAssertEqual(code(11), .network)
    }

    func testPositioningFailuresMapToTheirOwnCodes() {
        XCTAssertEqual(code(4),  .locatorsMissing)
        XCTAssertEqual(code(5),  .uwbSessionFailed)
        XCTAssertEqual(code(6),  .areaJudgeFailed)
        XCTAssertEqual(code(12), .deviceNotSupported)
    }

    /// 호출 순서 문제는 올리지 않는다 — 재시도마다 쌓여 진짜 오류를 덮는다.
    func testCallOrderComplaintsAreNotPromoted() {
        XCTAssertNil(code(2), "이미 측위 중")
        XCTAssertNil(code(8), "정지가 끝나기 전 start")
    }

    /// 모르는 코드를 아무 데나 붙이지 않는다. 엔진이 코드를 늘리면 조용히 오분류되는 대신
    /// 매핑에 없다는 사실이 그대로 드러나야 한다.
    func testUnknownCodesAreNotGuessed() {
        XCTAssertNil(code(0))
        XCTAssertNil(code(13))
        XCTAssertNil(code(99))
    }

    /// 매핑이 가리키는 코드는 전부 실재해야 한다 — 오타로 없는 코드를 부르면 안 된다.
    func testAllMappedCodesExist() {
        let known = Set(SdkErrorCode.allCases.map(\.rawValue))
        for hub in 1...12 {
            guard let c = code(hub) else { continue }
            XCTAssertTrue(known.contains(c.rawValue), "엔진 \(hub) → 없는 코드 \(c.rawValue)")
        }
    }
}

#endif
