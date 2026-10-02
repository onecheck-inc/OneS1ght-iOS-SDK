import XCTest
@testable import OneS1ght

/// SDK 는 신호를 전달만 한다 — 존을 대신 다시 받지 않는다.
@MainActor
final class SessionCoordinatorLiveTests: XCTestCase {

    private func makeCoordinator(suite: String) -> SessionCoordinator {
        Fixture.coordinator(suite: suite)
    }

    func testConfigChangeIsForwardedUntouched() {
        let coord = makeCoordinator(suite: "SessionCoordinatorLiveTests.forward")
        var got: [ConfigChange] = []
        coord.onConfigChange = { got.append($0) }

        coord.deliverConfigChange(.zonesChanged(floorId: "f-1"))
        coord.deliverConfigChange(.resyncNeeded)
        coord.deliverConfigChange(.rulesChanged(zoneId: "88"))

        XCTAssertEqual(got, [.zonesChanged(floorId: "f-1"),
                             .resyncNeeded,
                             .rulesChanged(zoneId: "88")])
    }

    // MARK: - 층 전환 시 스트림 재구독 판정
    //
    // 코디네이터는 주입받은 세션을 LiveConfigStream 에 물려준다(감사 K11 — 예전엔 안 물려줘 테스트가
    // 실제로 stub.test 에 SSE 연결을 시도했고 iOS 테스트 로그에 -1003 이 찍혔다). 그래도 여기서는
    // 재구독 여부를 결정하는 순수 판정(floorFilterChanged)을 검증한다 —
    // 이게 실제로 스트림을 다시 붙일지 말지를 가르는 유일한 조건이라, 여기가 틀리면
    // 리포트에 적힌 버그(층 전환 후 필터가 옛 층에 머무름)가 그대로 재발한다.

    private func floorState(building: String, floor: String, sessionId: Int? = nil) -> FloorState {
        FloorState(buildingId: building, floorId: floor, sessionId: sessionId,
                   locators: [], zones: [], hasPlan: true, locatorsFetchFailed: false)
    }

    func testFloorFilterUnchangedWhenNothingSet() {
        let coord = makeCoordinator(suite: "SessionCoordinatorLiveTests.unchanged-nil")
        XCTAssertFalse(coord.floorFilterChanged(from: nil, to: nil))
    }

    func testFloorFilterChangesFromNilToFloor() {
        let coord = makeCoordinator(suite: "SessionCoordinatorLiveTests.nil-to-floor")
        let a = floorState(building: "B1", floor: "F1")
        XCTAssertTrue(coord.floorFilterChanged(from: nil, to: a))
    }

    func testFloorFilterChangesFromFloorToNil() {
        // setFloorMap(nil, ...) — 층을 비우는 것도 "바뀜"이다(테넌트 전체 필터로 계속 받아야 한다).
        let coord = makeCoordinator(suite: "SessionCoordinatorLiveTests.floor-to-nil")
        let a = floorState(building: "B1", floor: "F1")
        XCTAssertTrue(coord.floorFilterChanged(from: a, to: nil))
    }

    func testFloorFilterChangesBetweenTwoDifferentFloors() {
        let coord = makeCoordinator(suite: "SessionCoordinatorLiveTests.floor-to-floor")
        let a = floorState(building: "B1", floor: "F1")
        let b = floorState(building: "B1", floor: "F2")
        XCTAssertTrue(coord.floorFilterChanged(from: a, to: b))
    }

    func testFloorFilterUnchangedWhenSameFloorReset() {
        // 같은 층으로 다시 setFloorMap 을 불러도(재조회 등) buildingId·floorId 가 같으면
        // 재구독하지 않는다 — 다른 필드(sessionId 등)가 달라져도 마찬가지.
        let coord = makeCoordinator(suite: "SessionCoordinatorLiveTests.same-floor")
        let a = floorState(building: "B1", floor: "F1", sessionId: nil)
        let a2 = floorState(building: "B1", floor: "F1", sessionId: 42)
        XCTAssertFalse(coord.floorFilterChanged(from: a, to: a2))
    }
}

/**
 스트림을 언제 붙여 둘 것인가.

 처음에는 측위 세션 구간에만 붙였다 — 동시 연결 수를 동시 체류 인원으로 묶으려는 의도였다.
 실기기에서 바로 드러났다: 초기화만 하고 층을 골라 도면을 보는 동안에는 콘솔에서 무엇을 바꿔도
 앱이 모른다. 수동 새로고침만 동작했다. 층을 띄워 둔 기기는 이미 "쓰고 있는" 기기라
 연결 수는 여전히 유계다.
 */
@MainActor
final class SessionCoordinatorStreamLifetimeTests: XCTestCase {

    /// 이번 수정의 핵심 — 측위를 시작하지 않아도 층만 정해지면 붙는다.
    func testStreamWantedWhenFloorSetWithoutSession() {
        XCTAssertTrue(SessionCoordinator.streamWanted(floorSet: true, running: false))
    }

    /// 종전 동작도 그대로 — 층이 아직 없어도 측위가 돌면 붙는다(상위집합이라 회귀가 없다).
    func testStreamWantedWhileRunningWithoutFloor() {
        XCTAssertTrue(SessionCoordinator.streamWanted(floorSet: false, running: true))
    }

    /// 둘 다 아니면 붙이지 않는다 — 앱만 켜 둔 기기까지 연결을 잡지는 않는다.
    func testStreamNotWantedWhenIdle() {
        XCTAssertFalse(SessionCoordinator.streamWanted(floorSet: false, running: false))
    }
}
