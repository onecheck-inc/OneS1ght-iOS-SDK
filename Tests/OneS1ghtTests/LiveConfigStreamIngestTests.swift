import XCTest
@testable import OneS1ght

/**
 실제 수신 경로 — 네트워크 바이트가 `ConfigChange` 로 나오기까지.

 이 테스트가 없어서 실기기에서 한참을 헤맸다. 연결 직후의 `.resyncNeeded` 는 파서를 거치지
 않고 나가기 때문에 "연결됨" 로그와 첫 갱신은 정상으로 보였고, 정작 `zones.changed` 는
 하나도 도착하지 않았다. 증상은 "새로고침을 눌러야 갱신된다" 뿐이라 원인이 드러나지 않았다.

 그래서 여기서 지키는 것은 **프레임이 실제로 조립되는가**다. 페이로드는 2026-08-25 prod
 `GET /api/sdk/v1/stream` 응답을 그대로 옮긴 것이다 — 하트비트 주석과 빈 줄 구분까지 포함해서.
 */
@MainActor
final class LiveConfigStreamIngestTests: XCTestCase {

    /// prod 실응답. 프레임 사이는 빈 줄 하나로 구분된다.
    private let realStream = """
    event:hello
    data:{"seq":36,"tenant_id":1}

    :ping

    event:zones.changed
    data:{"seq":37,"tenant_id":1,"store_id":3,"building_id":"b-1","floor_id":"14","origin":"agent.execute"}

    event:rules.changed
    data:{"seq":38,"tenant_id":1,"store_id":3,"zone_id":264,"rule_id":120,"status":"active"}


    """

    private func stream() -> LiveConfigStream {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return LiveConfigStream(baseURL: URL(string: "https://example.test/api/sdk/v1")!,
                                apiKey: "ock_test",
                                session: URLSession(configuration: cfg))
    }

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    /// 핵심 — 서버가 보낸 이벤트가 호스트까지 도착해야 한다.
    func testDeliversEventsFromRealServerPayload() async throws {
        StubURLProtocol.handler = { _ in (200, Data(self.realStream.utf8)) }

        let s = stream()
        var got: [ConfigChange] = []
        let done = expectation(description: "이벤트 수신")
        s.onChange = { change in
            got.append(change)
            // .resyncNeeded(연결) + zones.changed + rules.changed
            if got.count >= 3 { done.fulfill() }
        }

        s.start(buildingId: "b-1", floorId: "14")
        await fulfillment(of: [done], timeout: 5)
        s.stop()

        // 연결 자체가 올리는 신호는 파서를 거치지 않는다 — 이게 통과한다고 수신이 되는 게 아니다.
        XCTAssertEqual(got.first, .resyncNeeded)
        // 진짜로 확인해야 하는 것: 파서를 거쳐 온 이벤트들.
        XCTAssertTrue(got.contains(.zonesChanged(floorId: "14")),
                      "zones.changed 가 도착하지 않았다 — 프레임 조립이 깨졌다")
        XCTAssertTrue(got.contains(.rulesChanged(zoneId: "264")),
                      "rules.changed 가 도착하지 않았다")
    }

    /// 하트비트 주석만 오는 동안에는 호스트에 아무것도 올리지 않는다.
    ///
    /// 연결(.resyncNeeded)이 온 것을 조건으로 기다린 뒤, 본문을 다 읽을 틈만 짧게 준다. 예전엔 800ms 를
    /// 고정으로 기다렸는데, 재연결 백오프(1초 ±20% = 최소 0.8초)와 겹쳐 느린 CI 에서는 두 번째 연결의
    /// .resyncNeeded 가 끼어들 수 있었다(감사 K16).
    func testHeartbeatAloneDeliversNothingBeyondConnect() async throws {
        StubURLProtocol.handler = { _ in (200, Data(":ping\n\n:ping\n\n".utf8)) }

        let s = stream()
        let got = Collected<ConfigChange>()
        s.onChange = { got.append($0) }       // 스트림 작업(메인 밖)에서 불린다

        s.start(buildingId: nil, floorId: nil)
        await waitUntil { !got.items.isEmpty }
        await settle(0.1)
        s.stop()

        XCTAssertEqual(got.items, [.resyncNeeded])
    }
}

/// 메인 밖에서 불리는 콜백을 모으는 상자.
final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ x: T) { lock.lock(); storage.append(x); lock.unlock() }
    var items: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}
