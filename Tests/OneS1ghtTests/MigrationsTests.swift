//
//  MigrationsTests.swift
//  Migrations/ios.json 이 실제 판올림을 따라오는지 지킨다.
//
//  마이그레이션 지침이 없으면 MCP 는 "변경 없음" 이라고 답할 근거가 없고, 에이전트는
//  추측으로 고객사 코드를 고친다. 그래서 파일이 낡는 것을 빌드에서 잡는다.
//
//  가장 중요한 검사는 **경로 연속성**이다. 0.1.0 → 0.1.1 → 0.2.0 처럼 칸이 이어져야
//  "지금 0.1.0 인데 최신으로 올리려면" 에 답할 수 있다. 한 칸이라도 비면 그 앞의 사용자는
//  건너뛸 방법이 없다.
//

import XCTest
@testable import OneS1ght

final class MigrationsTests: XCTestCase {

    private static let url: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Tests/OneS1ghtTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo root>
            .appendingPathComponent("Migrations/ios.json")
    }()

    private var json: [String: Any] {
        get throws {
            let data = try Data(contentsOf: Self.url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw XCTSkip("ios.json 이 객체가 아니다")
            }
            return obj
        }
    }

    private var steps: [[String: Any]] {
        get throws { (try json["migrations"] as? [[String: Any]]) ?? [] }
    }

    func testFileParses() throws {
        XCTAssertEqual(try json["platform"] as? String, "ios")
    }

    /// ⚠️ 판올림하면서 이 파일을 안 고치면 여기서 걸린다.
    func testCurrentVersionMatchesTheSdk() throws {
        XCTAssertEqual(try json["currentVersion"] as? String, OneS1ght.sdkVersion,
                       "Migrations/ios.json 의 currentVersion 이 OneS1ght.sdkVersion 과 다르다 — 판올림 때 칸을 더할 것")
    }

    /// 마지막 칸의 to 가 현재 버전이어야 한다. 아니면 최신으로 가는 길이 없다.
    func testLatestMigrationLandsOnCurrentVersion() throws {
        guard let last = try steps.last else {
            return XCTFail("마이그레이션이 하나도 없다 — 첫 판올림부터 기록할 것")
        }
        XCTAssertEqual(last["to"] as? String, OneS1ght.sdkVersion,
                       "마지막 마이그레이션의 to 가 현재 버전이 아니다")
    }

    /// **경로 연속성** — 앞 칸의 to 가 다음 칸의 from 이어야 이어 밟을 수 있다.
    func testMigrationChainHasNoGaps() throws {
        let all = try steps
        for (i, step) in all.enumerated() where i > 0 {
            let prevTo = all[i - 1]["to"] as? String
            let from = step["from"] as? String
            XCTAssertEqual(from, prevTo,
                           "경로가 끊겼다: \(prevTo ?? "?") 다음이 \(from ?? "?") 에서 시작한다")
        }
    }

    /// 모든 칸에 사람이 읽을 요약과 할 일이 있어야 한다.
    func testEveryMigrationExplainsItself() throws {
        for step in try steps {
            let label = "\(step["from"] ?? "?")→\(step["to"] ?? "?")"
            XCTAssertNotNil(step["summary"] as? String, label)
            XCTAssertFalse((step["summary"] as? String ?? "").isEmpty, label)
            XCTAssertNotNil(step["action"] as? String, label)
            XCTAssertNotNil(step["breaking"] as? Bool, "\(label) — breaking 을 명시할 것")
        }
    }

    /**
     * ⚠️ breaking 이면 무엇을 고쳐야 하는지가 반드시 있어야 한다.
     * "깨지는 변경입니다" 만 알려주고 방법을 안 주면 에이전트가 추측한다 —
     * 그 추측이 고객사 코드에 그대로 들어간다.
     */
    func testBreakingChangesCarryInstructions() throws {
        for step in try steps where (step["breaking"] as? Bool) == true {
            let changes = (step["changes"] as? [[String: Any]]) ?? []
            XCTAssertFalse(changes.isEmpty,
                           "\(step["from"] ?? "?")→\(step["to"] ?? "?") 는 breaking 인데 changes 가 비어 있다")
            for c in changes {
                XCTAssertNotNil(c["before"], "변경 전 코드가 없다")
                XCTAssertNotNil(c["after"], "변경 후 코드가 없다")
            }
        }
    }

    /// 같은 구간이 두 번 적히면 에이전트가 어느 쪽을 따를지 모른다.
    func testNoDuplicateMigrationSteps() throws {
        let pairs = try steps.map { "\($0["from"] ?? "?")→\($0["to"] ?? "?")" }
        XCTAssertEqual(Set(pairs).count, pairs.count, "중복된 구간이 있다: \(pairs)")
    }
}
