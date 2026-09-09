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

    /// 권한 계열 셋(BT 불가·위치 불가·Info.plist 키 누락)은 모두 E2003 이다 —
    /// 관리자가 할 일이 같다: 사용자에게 설정을 안내한다.
    func testPermissionFamilyMapsToPermissionDenied() {
        XCTAssertEqual(code(3), .permissionDenied)
        XCTAssertEqual(code(7), .permissionDenied)
        XCTAssertEqual(code(9), .permissionDenied)
    }

    /// 라이선스 계열은 키 문제다 — 재시도해도 소용없다는 뜻이 담긴 코드로 간다.
    func testLicenseFamilyMapsToInvalidKey() {
        XCTAssertEqual(code(1),  .invalidKey, "라이선스 미등록")
        XCTAssertEqual(code(10), .invalidKey, "서버가 거부")
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
