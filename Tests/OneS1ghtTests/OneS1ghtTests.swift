//
//  OneS1ghtTests.swift
//  [뼈대 단계] 패키지가 빌드·테스트 되는지만 확인. 실 테스트는 각 단계에서 추가 (TDD).
//

import XCTest
@testable import OneS1ght

final class OneS1ghtTests: XCTestCase {
    func testSdkVersion() {
        XCTAssertEqual(OneS1ght.sdkVersion, "0.1.0")
    }
}
