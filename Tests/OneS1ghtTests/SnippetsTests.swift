//
//  SnippetsTests.swift
//  Snippets/ios.json 이 실제 SDK 와 어긋나지 않는지 지킨다.
//
//  이 파일이 있는 이유는 하나다 — 스니펫은 **고객사 코드에 그대로 들어간다.**
//  코딩 에이전트(MCP)가 받아 그들의 프로젝트에 붙이므로, 사람이 읽고 옮겨 적을 때처럼
//  "어? 이건 아닌데" 하고 걸러 주는 단계가 없다. 한 글자 틀리면 그대로 심긴다.
//
//  실제로 2026-08-20 에 같은 일이 있었다. 층 미지정 로그가 이미 사라진 loadFloor 를
//  안내하고 있었고, 문서·콘솔·README 세 곳이 전부 옛 API 였다.
//  스니펫을 SDK 와 같은 레포·같은 태그에 두고 이 테스트로 묶는 것이 그 재발 방지책이다.
//

import XCTest
@testable import OneS1ght

final class SnippetsTests: XCTestCase {

    /// 레포 루트의 Snippets/ios.json — 패키지 리소스가 아니라 소스 트리에서 직접 읽는다.
    /// 런타임에는 필요 없는 파일이라 번들에 넣지 않는다(앱 크기에 얹을 이유가 없다).
    private static let snippetURL: URL = {
        URL(fileURLWithPath: #filePath)          // Tests/OneS1ghtTests/SnippetsTests.swift
            .deletingLastPathComponent()          // Tests/OneS1ghtTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo root>
            .appendingPathComponent("Snippets/ios.json")
    }()

    private var json: [String: Any] {
        get throws {
            let data = try Data(contentsOf: Self.snippetURL)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw XCTSkip("ios.json 이 객체가 아니다")
            }
            return obj
        }
    }

    private var steps: [[String: Any]] {
        get throws { (try json["steps"] as? [[String: Any]]) ?? [] }
    }

    /// 스니펫 전체를 하나의 문자열로 — 메서드 이름이 어디에 있든 잡는다.
    private var allCode: String {
        get throws {
            var out = ""
            for step in try steps {
                if let c = step["code"] as? String { out += c + "\n" }
                for f in (step["files"] as? [[String: Any]]) ?? [] {
                    if let c = f["code"] as? String { out += c + "\n" }
                }
            }
            return out
        }
    }

    func testFileParses() throws {
        XCTAssertEqual(try json["platform"] as? String, "ios")
        XCTAssertFalse(try steps.isEmpty)
    }

    /// ⚠️ 핵심 — 버전을 올리면서 스니펫을 안 고치면 여기서 걸린다.
    /// 이 한 줄이 "SDK 는 바뀌었는데 안내는 옛것" 상태를 막는다.
    func testDeclaredVersionMatchesTheSdk() throws {
        XCTAssertEqual(try json["sdkVersion"] as? String, OneS1ght.sdkVersion,
                       "Snippets/ios.json 의 sdkVersion 이 OneS1ght.sdkVersion 과 다르다 — 판올림 때 함께 고칠 것")
    }

    /// 스니펫이 참조하는 에러 코드가 실제로 존재하는가.
    /// 없는 코드를 안내하면 에이전트가 사전에서 못 찾고 헤맨다.
    func testReferencedErrorCodesExist() throws {
        let known = Set(SdkErrorCode.allCases.map(\.rawValue))
        for step in try steps {
            for raw in (step["throws"] as? [String]) ?? [] {
                XCTAssertTrue(known.contains(raw),
                              "\(step["id"] ?? "?") 가 존재하지 않는 코드를 참조한다: \(raw)")
            }
        }
    }

    /// 사라진 API 이름이 스니펫에 남아 있지 않은가.
    /// 재설계 때 실제로 이 이름들이 문서 곳곳에 남아 사람을 막다른 길로 보냈다.
    func testNoRetiredApiNames() throws {
        let code = try allCode
        for retired in ["OneS1ghtSDK", "loadFloor", "start(consent:", "geospaceKey",
                        "positioningAvailability", "anonUserId", "onZoneEvent",
                        "onesight-sdk"] {
            XCTAssertFalse(code.contains(retired), "스니펫에 사라진 이름이 남아 있다: \(retired)")
        }
    }

    /**
     * ⚠️ 컴파일되지 않는 패턴이 스니펫에 들어가면 안 된다.
     *
     * `savedProfileId ?? (try await ...)` 가 실제로 들어 있었고, 그대로는 컴파일되지 않는다 —
     * `??` 오른쪽은 autoclosure 라 try/await 를 담을 수 없다.
     *
     * ```
     * error: operator can throw but expression is not marked with 'try'
     * error: 'async' call in an autoclosure that does not support concurrency
     * ```
     *
     * 스니펫은 코딩 에이전트가 **그대로 복사해 고객 코드에 넣는다.** 눈으로 읽어서는
     * 멀쩡해 보이므로, 알려진 함정은 이렇게 못 박아 둔다.
     */
    func testNoUncompilablePatterns() throws {
        // ⚠️ 주석은 걸러낸다 — 함정을 설명하는 주석에 그 패턴이 그대로 나온다.
        //    검사 대상은 "컴파일되는 부분" 이지 설명이 아니다.
        let code = try allCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[line.startIndex..<slash.lowerBound]
            }
            .joined(separator: "\n")
        let patterns = [
            ("?? (try", "`??` 오른쪽은 autoclosure — try 를 담을 수 없다"),
            ("?? (await", "`??` 오른쪽은 autoclosure — await 를 담을 수 없다"),
            ("?? try", "`??` 오른쪽은 autoclosure — try 를 담을 수 없다"),
        ]
        for (pattern, why) in patterns {
            XCTAssertFalse(code.contains(pattern),
                           "스니펫에 컴파일되지 않는 패턴이 있다: \(pattern) — \(why)")
        }
    }

    /// 연동에 반드시 필요한 단계가 빠지지 않았는가.
    /// 특히 profile·selectFloor 는 빠뜨리면 조용히 실패하는 단계다(E1004·E3001).
    func testRequiredStepsArePresent() throws {
        let ids = try steps.compactMap { $0["id"] as? String }
        for required in ["install", "permission", "initialize", "profile", "selectFloor", "begin", "end"] {
            XCTAssertTrue(ids.contains(required), "필수 단계 누락: \(required)")
        }
    }

    /// order 가 중복되거나 비면 에이전트가 순서를 못 잡는다.
    func testStepOrderIsUniqueAndComplete() throws {
        let orders = try steps.compactMap { $0["order"] as? Int }
        XCTAssertEqual(orders.count, try steps.count, "order 가 없는 단계가 있다")
        XCTAssertEqual(Set(orders).count, orders.count, "order 가 중복된다")
    }

    /// 스니펫이 부르는 공개 메서드가 실제 표면에 있는가 — 이름을 문자열로 대조한다.
    /// (컴파일로 잡는 편이 낫지만 스니펫은 조각이라 그대로는 안 붙는다)
    func testCoreApiNamesAppear() throws {
        let code = try allCode
        for expected in ["OneS1ght.initialize(", "OneS1ght.createProfile(", "OneS1ght.identify(",
                         "OneS1ght.buildings(", "OneS1ght.floors(", "OneS1ght.setFloorMap(",
                         "OneS1ght.floorSession(", "session.begin(", "OneS1ght.deviceAvailability"] {
            XCTAssertTrue(code.contains(expected), "핵심 API 가 스니펫에 없다: \(expected)")
        }
    }

    /// 안내 문구가 실제 요구사항과 맞는가 — Xcode 27 같은 옛 값이 남지 않게.
    func testRequirementsAreCurrent() throws {
        let req = try json["requirements"] as? [String: Any] ?? [:]
        let build = req["build"] as? [String: String] ?? [:]
        XCTAssertEqual(build["xcode"], "26.6+", "실제로 빌드되는 Xcode 버전과 맞출 것")

        let positioning = req["positioning"] as? [String: String] ?? [:]
        XCTAssertEqual(positioning["os"], "iOS 27.0+")
    }
}
