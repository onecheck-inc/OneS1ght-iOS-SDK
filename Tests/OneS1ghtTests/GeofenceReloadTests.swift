//
//  GeofenceReloadTests.swift
//  구역이 바뀌면 판정 엔진이 그 사실을 알게 되는가.
//

import XCTest
@testable import OneS1ght

/// **지도에는 보이는데 판정만 안 나오는 상태**를 막는다.
///
/// 측위 엔진은 지오펜스를 **자기 서버에서** 받고, 그것을 `start()` 때 **한 번만** 읽는다.
/// 그래서 콘솔에서 구역을 새로 그리면 SDK 는 그 구역을 받아 지도에 그리지만, 엔진은 끝까지
/// 모른다 — 진입·이탈이 영원히 안 나온다. 2026-09-10 실기기에서 실제로 그랬고,
/// 판정 엔진 로그에 `영역 추가` 가 `start` 시점에만 찍히는 것으로 확인됐다.
///
/// 이 부류는 **오류가 안 난다.** 지도가 멀쩡히 그려지므로 눈으로는 정상과 구분되지 않는다.
/// 그래서 "구역이 바뀌면 엔진에 알린다" 를 값이 아니라 동작으로 못 박는다.
@MainActor
final class GeofenceReloadTests: XCTestCase {

    private func zone(_ id: String) -> Zone {
        Zone(id: id, name: "z-\(id)", polygon: [Position(x: 0, y: 0), Position(x: 1, y: 0),
                                                Position(x: 1, y: 1)])
    }

    // MARK: - 무엇을 "바뀌었다" 로 볼 것인가

    func test_구역이_늘면_다시_읽어야_한다() {
        XCTAssertTrue(SessionCoordinator.geofencesChanged(from: [zone("a")], to: [zone("a"), zone("b")]))
    }

    func test_구역이_줄면_다시_읽어야_한다() {
        XCTAssertTrue(SessionCoordinator.geofencesChanged(from: [zone("a"), zone("b")], to: [zone("a")]))
    }

    /// ⚠️ 구역을 **다시 그리면 콘솔이 새 id 를 준다**(실측 `020461cd…` → `258dae1e…`).
    /// 이름이 같아도 도형이 달라졌으므로 엔진은 반드시 다시 읽어야 한다 — 안 그러면
    /// 옛 폴리곤으로 판정해서 "가끔 맞고 가끔 틀린" 최악의 증상이 된다.
    func test_같은_이름이라도_id_가_바뀌면_다시_읽어야_한다() {
        XCTAssertTrue(SessionCoordinator.geofencesChanged(from: [zone("020461cd")], to: [zone("258dae1e")]))
    }

    /// 이 경로는 앱이 5초마다 폴링한다. 안 바뀐 걸 바뀌었다고 하면 엔진이 계속 껐다 켜져
    /// 측위가 아예 서지 못한다 — 고치려던 것보다 나쁜 고장이 된다.
    func test_같은_구역이면_건드리지_않는다() {
        XCTAssertFalse(SessionCoordinator.geofencesChanged(from: [zone("a"), zone("b")],
                                                           to: [zone("b"), zone("a")]),
                       "순서만 다른 것을 변경으로 보면 폴링마다 엔진이 재시작된다")
    }

    /// 처음 층을 잡을 때 서버에 구역이 아직 없으면 엔진은 판정을 아예 시작하지 않는다
    /// (실기기 로그: `PrmImpl created` 만 있고 `start` 가 없다). 나중에 구역이 생겼을 때
    /// 반드시 다시 읽혀야 그 세션이 회복된다 — 안 하면 앱을 껐다 켜야만 낫는다.
    func test_없다가_생기면_다시_읽어야_한다() {
        XCTAssertTrue(SessionCoordinator.geofencesChanged(from: [], to: [zone("a")]))
    }

    func test_전부_지우면_다시_읽어야_한다() {
        XCTAssertTrue(SessionCoordinator.geofencesChanged(from: [zone("a")], to: []))
    }

    // MARK: - 프로바이더가 실제로 통보를 받는가

    /// 엔진이 없는 구현(Mock 등)은 기본 no-op 이어야 한다 — 프로토콜에 필수로 넣으면
    /// 호스트가 만든 커스텀 프로바이더가 전부 컴파일이 깨진다.
    func test_엔진이_없는_프로바이더는_무시한다() {
        final class Bare: PositioningProvider {
            var delegate: PositioningProviderDelegate?
            func start() {}
            func stop() {}
        }
        let bare = Bare()
        bare.reloadGeofences()      // 기본 구현이 없으면 컴파일부터 안 된다
    }

    func test_Mock_은_통보를_기록한다() {
        let p = MockPositioningProvider()
        XCTAssertEqual(p.reloadGeofencesCount, 0)
        p.reloadGeofences()
        p.reloadGeofences()
        XCTAssertEqual(p.reloadGeofencesCount, 2)
    }
}
