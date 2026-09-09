//
//  SdkLogLevelPolicyTests.swift
//  등급 기준을 코드로 고정한다 — SdkErrorCode.swift 머리말의 "등급 기준"이 말로만
//  남으면, 다음 사람이 새 코드를 넣을 때 습관대로 ERROR 를 붙인다.
//
//  0.1.18 까지 실제로 그랬다: 미지원 기기·꺼 둔 설정·구역 없는 층처럼 **고장이 아닌
//  상태**가 전부 ERROR 로 찍혀, 정상 기기들이 콘솔 로그 분석기를 채우고 그 소음 속에
//  진짜 고장이 묻혔다.
//

import XCTest
@testable import OneS1ght

final class SdkLogLevelPolicyTests: XCTestCase {

    /// 고칠 것이 없는 사실은 ERROR 가 아니다.
    ///
    /// 이 둘은 우리가 설계로 보장한 "미지원 기기에서도 앱은 살아 있다" 의 바로 그
    /// 상태다. 여기가 ERROR 로 돌아가면 그 보장이 로그상으로는 사고처럼 보인다.
    func testDeviceFactsAreInfo() {
        XCTAssertEqual(SdkErrorCode.osVersionTooLow.level, .info)
        XCTAssertEqual(SdkErrorCode.deviceNotSupported.level, .info)
    }

    /// 정상 경로이거나 계속 동작하는 상태는 ERROR 가 아니다.
    func testBenignStatesAreNotError() {
        for code: SdkErrorCode in [
            .positioningDisabled,   // 테넌트가 일부러 꺼 둔 설정
            .permissionDenied,      // 설정에서 풀 수 있다
            .floorNotSet,           // BLE 흐름에서는 정상 경로
            .locatorsMissing,       // 설치 전 층일 수 있다
            .sessionIdMissing,
            .zonesEmpty,            // 구역이 없을 뿐 — 지도는 그대로 뜬다
            .floorNotDetected, .zoneMappingFailed, .areaJudgeFailed,
            .locatorNotReceived, .pendingDropped,
        ] {
            XCTAssertNotEqual(code.level, .error, "\(code.rawValue) 는 고장이 아니다")
        }
    }

    /// 진짜 실패는 ERROR 로 남아야 한다 — 위 완화가 과하게 번지면 이 테스트가 잡는다.
    func testRealFailuresStayError() {
        for code: SdkErrorCode in [
            .notInitialized, .invalidKey, .notIdentified, .keyUnavailable,
            .locatorsFetchFailed, .floorIdMismatch, .uwbSessionFailed,
            .noPositionFix,         // 3대 이상 들리는데 못 푼다 = 배치 불일치
            .network, .server, .unprocessable, .forbidden, .decoding,
        ] {
            XCTAssertEqual(code.level, .error, "\(code.rawValue) 는 진짜 실패다")
        }
    }

    /// 모든 코드가 위 세 목록 중 하나에는 들어 있어야 한다 — 새 코드를 넣고 이 파일을
    /// 안 고치면 여기서 걸린다(등급을 생각 안 하고 넘어가는 것을 막는 자리다).
    func testEveryCodeIsClassified() {
        let known: Set<SdkErrorCode> = [
            .osVersionTooLow, .deviceNotSupported,
            .positioningDisabled, .permissionDenied, .floorNotSet, .locatorsMissing,
            .sessionIdMissing, .zonesEmpty, .noPositionFix, .floorNotDetected,
            .zoneMappingFailed, .areaJudgeFailed, .locatorNotReceived, .pendingDropped,
            .notInitialized, .invalidKey, .notIdentified, .keyUnavailable,
            .locatorsFetchFailed, .floorIdMismatch, .uwbSessionFailed,
            .network, .server, .unprocessable, .forbidden, .decoding,
        ]
        let missing = SdkErrorCode.allCases.filter { !known.contains($0) }
        XCTAssertTrue(missing.isEmpty,
                      "등급이 분류되지 않은 코드: \(missing.map(\.rawValue))")
    }
}
