//
//  DeprecatedNamesTests.swift
//  0.1.24 까지의 공개 이름이 경고만 내고 그대로 동작하는가(2026-10-02 감사 K13).
//
//  고객 코드(그리고 사내 온보딩 앱)는 옛 이름으로 짜여 있다. 이름을 바꾸면서 옛 이름을 지우면
//  판올림 한 번에 컴파일이 깨진다 — deprecated 로 남겨 새 이름으로 넘기기만 한다.
//  테스트 메서드에 deprecated 를 붙여 그 경고가 테스트 빌드를 덮지 않게 한다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class DeprecatedNamesTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await OneS1ght.reset()
    }

    @available(*, deprecated)
    func testOldSpaceNamesForwardToNewOnes() async {
        // 초기화 전이면 새 이름과 똑같이 notInitialized 를 던져야 한다 — 그대로 넘겼다는 뜻이다.
        let calls: [() async throws -> Void] = [
            { _ = try await OneS1ght.floors("B") },
            { _ = try await OneS1ght.floor("B", "F") },
            { _ = try await OneS1ght.zones("B", "F") },
            { _ = try await OneS1ght.locators("B", "F") },
            { try await OneS1ght.setFloorMap(nil, buildingID: "B") },
            { _ = try await OneS1ght.getProfile("p") },
            { try await OneS1ght.putProfile("p", [:]) },
        ]
        for call in calls {
            do { try await call(); XCTFail("초기화 전인데 통과했다") }
            catch { XCTAssertEqual(error as? SdkError, .notInitialized) }
        }
        OneS1ght.empty()
        await OneS1ght.send()
        XCTAssertEqual(ApiClient.defaultBaseURL, OneS1ght.defaultBaseURL)
    }

    @available(*, deprecated)
    func testTriggerOldNames() {
        let t = Trigger(trigger_id: "a1", type: "coupon", payload: nil)
        XCTAssertEqual(t.trigger_id, "a1")
        XCTAssertEqual(t.triggerId, "a1")
    }

    /// Swift 이름만 바뀌었다 — 서버 계약(JSON 키)은 그대로 trigger_id 다.
    func testTriggerWireNameIsUnchanged() throws {
        let t = Trigger(triggerId: "a1", type: "coupon", payload: ["title": "커피"])
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any]
        XCTAssertEqual(obj?["trigger_id"] as? String, "a1")
        XCTAssertNil(obj?["triggerId"])
        let back = try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }
}
