import XCTest
@testable import OneS1ght

/// 갭 판정 — 이벤트를 놓쳤다면 .resyncNeeded 로 알린다.
/// (연결·재연결은 실기기 검증 대상이고, 여기서는 판정 규칙만 못 박는다.)
final class LiveConfigStreamGapTests: XCTestCase {

    private func stream() -> LiveConfigStream {
        LiveConfigStream(baseURL: URL(string: "https://example.test/api/sdk/v1")!,
                         apiKey: "ock_test", session: .shared)
    }

    private func frame(_ event: String, _ seq: Int) -> SseFrame {
        SseFrame(event: event, data: "{\"seq\":\(seq),\"tenant_id\":7,\"floor_id\":\"f-1\"}")
    }

    func testConsecutiveSeqDoesNotAskForResync() {
        let s = stream()
        var got: [ConfigChange] = []
        s.onChange = { got.append($0) }

        s.acceptForTest(frame("hello", 10))
        s.acceptForTest(frame("zones.changed", 11))
        s.acceptForTest(frame("zones.changed", 12))

        XCTAssertFalse(got.contains(.resyncNeeded))
        XCTAssertEqual(got, [.zonesChanged(floorId: "f-1"), .zonesChanged(floorId: "f-1")])
    }

    func testSeqGapAsksForResync() {
        let s = stream()
        var got: [ConfigChange] = []
        s.onChange = { got.append($0) }

        s.acceptForTest(frame("hello", 10))
        s.acceptForTest(frame("zones.changed", 14))     // 11·12·13 을 놓쳤다

        XCTAssertEqual(got.first, .resyncNeeded)         // 놓친 것을 먼저 알린다
        XCTAssertTrue(got.contains(.zonesChanged(floorId: "f-1")))
    }

    func testSeqGoingBackwardsAlsoAsksForResync() {
        // Redis 가 초기화되면 seq 가 1 로 되감긴다 — 안전한 방향으로 틀려야 한다.
        let s = stream()
        var got: [ConfigChange] = []
        s.onChange = { got.append($0) }

        s.acceptForTest(frame("hello", 500))
        s.acceptForTest(frame("zones.changed", 1))

        XCTAssertEqual(got.first, .resyncNeeded)
    }

    func testHelloAloneDeliversNothing() {
        // 연결 직후 기준선만 잡는다 — 그 자체로는 고객사에게 알릴 변경이 없다.
        let s = stream()
        var got: [ConfigChange] = []
        s.onChange = { got.append($0) }

        s.acceptForTest(frame("hello", 1))

        XCTAssertTrue(got.isEmpty)
    }
}
