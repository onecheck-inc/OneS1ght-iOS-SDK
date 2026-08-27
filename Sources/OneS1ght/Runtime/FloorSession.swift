//
//  FloorSession.swift
//  측위 세션 — 앱이 측위를 켜고 끄고 이벤트를 받는 인스턴스.
//
//  · 층은 setFloorMap 이 이미 잡아 두었으므로 만들 때 인자가 없다.
//  · **싱글턴** — UWB 라디오·판정 엔진·좌표 버퍼가 기기당 하나뿐이라
//    세션이 여럿이면 물리적으로 충돌한다. floorSession() 은 항상 같은 인스턴스를 준다.
//  · 가동 중 setFloorMap 을 다시 부르면 이 세션이 새 층으로 갈아탄다(재생성 불필요).
//  · begin/end 로 이름 지은 이유 — `in` 은 Swift 예약어라 백틱 없이 못 쓰고,
//    enter/exit 는 존 이벤트(onZoneEnter/onZoneExit)와 단어가 겹친다.
//

import Foundation

@MainActor
public final class FloorSession {

    // MARK: - 이벤트 수신

    /// 구역 진입 — 온디바이스 판정 즉시 (서버 왕복 없음)
    public var onZoneEnter: ((Zone) -> Void)?
    /// 구역 이탈
    public var onZoneExit: ((Zone) -> Void)?
    /// 구역 체류 — dwellSeconds 도달 시 1회 (반복 발화 없음 — 서버 시책 중복 방지)
    public var onZoneDwell: ((Zone, TimeInterval) -> Void)?
    /// 실시간 좌표 (도면 로컬 미터) — 지도에 내 위치를 그리는 표준 훅
    public var onPosition: ((Coordinates) -> Void)?
    /// 존 이벤트 서버 응답의 개인화 액션 — (zoneId, [Trigger])
    public var onTriggers: ((String, [Trigger]) -> Void)?

    /// 콘솔에서 무언가 바뀌었다 — 지도를 다시 그리거나 구역을 다시 받을 때 쓴다.
    ///
    /// **SDK 는 이 신호로 아무것도 하지 않는다.** 무엇을 다시 받을지는 앱이 정한다.
    /// 보통은 이렇게 쓴다:
    ///
    /// - `.zonesChanged` / `.resyncNeeded` → `OneS1ght.refreshZones()` 로 구역을 다시 받는다.
    ///   ⚠️ **연속해서 오면 접어라(권장 1초).** 구역을 다시 물릴 때마다 진출입 판정이 처음부터
    ///   시작돼, 접지 않으면 쿠폰이 난사되고 체류 타이머가 매번 초기화된다.
    /// - `.rulesChanged` → **지금 들어가 있는 구역이 있으면 그 구역의 이벤트를 한 번 다시 조회하라.**
    ///   시책을 켜는 경로 중 활성화·연결은 구역을 만들지 않아 판정이 재시작되지 않는다 —
    ///   이 신호를 무시하면 구역 안에 이미 서 있는 사람은 나갔다 들어와야 시책을 받는다.
    ///   서버가 세션별 수신기록으로 중복을 막으므로 몇 번을 조회해도 안전하다.
    public var onConfigChanged: ((ConfigChange) -> Void)?

    // MARK: - 상태

    /// 이 세션이 보고 있는 층 — setFloorMap 이 정한 값. nil 이면 층 미지정.
    public var floor: Floor? { coordinator?.currentFloor }

    /// 측위 가동 중인가
    public var isRunning: Bool { coordinator?.isRunning ?? false }

    // MARK: - 제어

    /// 측위 시작 (매장 진입 시).
    /// - throws: .notInitialized / .notIdentified / .deviceNotSupported / .osVersionTooLow
    public func begin() async throws {
        #if os(iOS)
        guard #available(iOS 27.0, *) else { throw SdkError.osVersionTooLow }
        // 시뮬레이터는 여기서 막힌다 (UWB 칩 없음). 테스트는 begin(provider:) 로 Mock 주입.
        guard UwbPositioningProvider.isSupported else { throw SdkError.deviceNotSupported }
        let uwb = (builtInProvider as? UwbPositioningProvider) ?? UwbPositioningProvider()
        builtInProvider = uwb
        uwb.onZoneEvent = { [weak self] event in self?.dispatch(event) }
        uwb.onLog = { level, line in OneS1ght.onDebugLog?(level, line) }   // 엔진 로그 → 표준 디버그 훅
        try await begin(provider: uwb)
        #else
        throw SdkError.deviceNotSupported
        #endif
    }

    /// 측위 시작 (커스텀 측위 주입) — 테스트(Mock)·데모 등 특수 경우용.
    public func begin(provider: PositioningProvider) async throws {
        guard let coordinator else { throw SdkError.notInitialized }
        if !coordinator.isPrepared { try await coordinator.prepare() }   // 순단 회복
        try await coordinator.start(provider: provider)
    }

    /// 측위 종료 + 잔여 좌표 전송. 초기화·층 설정은 유지 → begin 재호출로 재개.
    public func end() async {
        await coordinator?.stop()
    }

    // MARK: - 내부

    /// ZoneEvent → 분리된 콜백. 통짜 enum 을 받던 종전 onZoneEvent 의 후신.
    private func dispatch(_ event: ZoneEvent) {
        switch event {
        case .enter(let zone, _):          onZoneEnter?(zone)
        case .exit(let zone, _):           onZoneExit?(zone)
        case .dwell(let zone, let s, _):   onZoneDwell?(zone, s)
        }
    }

    private var coordinator: SessionCoordinator? { OneS1ght.coordinatorRef }
    private var builtInProvider: PositioningProvider?    // 내장 provider 재사용 (재시작 대비)

    /// 세션 싱글턴 — floorSession() 만 접근.
    static let shared = FloorSession()
    private init() {}
}
