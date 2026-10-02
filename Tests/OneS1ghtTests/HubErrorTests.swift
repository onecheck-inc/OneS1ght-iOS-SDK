//
//  HubErrorTests.swift
//  엔진 오류 번호의 뜻이 한 곳(HubError)에서만 정해지는가 — 맥에서도 돈다(감사 K15).
//

import XCTest
@testable import OneS1ght

final class HubErrorTests: XCTestCase {

    /// 시작 단계에서 나면 엔진이 아예 못 뜬 것 — 2026-09-28 Bluetooth 고착 수정 때 정한 목록 그대로.
    func testAbortsStartSet() {
        XCTAssertEqual(Set(HubError.allCases.filter(\.abortsStart).map(\.rawValue)), [1, 3, 7, 9, 10, 11, 12])
    }

    /// 사람이 풀어야 하는 것 — 다시 켜 보지 않는다(2026-10-02 복귀 재시작).
    func testNeedsPersonSet() {
        XCTAssertEqual(Set(HubError.allCases.filter(\.needsPerson).map(\.rawValue)), [1, 3, 7, 10])
    }

    /// 호출 순서 문제(2·8)만 코드로 올리지 않는다.
    func testOnlyCallOrderComplaintsAreSilent() {
        XCTAssertEqual(Set(HubError.allCases.filter { $0.sdkCode() == nil }.map(\.rawValue)), [2, 8])
        XCTAssertEqual(HubError.bluetoothUnavailable.sdkCode(message: "bluetooth unavailable: powered off"),
                       .bluetoothOff)
    }

    func testNumbersAreOneThroughTwelve() {
        XCTAssertEqual(HubError.allCases.map(\.rawValue), Array(1...12))
    }
}
