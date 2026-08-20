//
//  OneS1ghtTests.swift
//  패키지가 빌드·테스트 되는지와 버전 문자열의 형식만 확인한다.
//

import XCTest
@testable import OneS1ght

final class OneS1ghtTests: XCTestCase {

    /// 버전 형식만 본다. 값을 여기 박아 두면 판올림마다 이 테스트가 깨지는데,
    /// 그때 사람은 "버전을 올렸으니 당연하지" 하고 숫자만 고친다 — 검사가 아니라 잡일이 된다.
    /// (실제로 0.1.1 판올림 때 여기가 깨진 채로 머지됐다.)
    ///
    /// 값이 맞는지는 다른 곳이 지킨다.
    ///  · SnippetsTests   — Snippets/ios.json 의 sdkVersion 과 일치하는가
    ///  · MigrationsTests — Migrations/ios.json 의 currentVersion 과 일치하는가
    ///  · Scripts/release.sh — 태그 번호 · CHANGELOG 항목과 일치하는가
    func testSdkVersionIsSemver() {
        let v = OneS1ght.sdkVersion
        XCTAssertFalse(v.isEmpty)
        XCTAssertNotNil(v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
                        "버전이 x.y.z 형식이 아니다: \(v)")
    }
}
