//
//  MockPositioningProvider.swift
//  테스트/데모용 가짜 측위 — 콜백을 프로그램적으로 발생시켜 SDK 파이프라인을 검증
//
//  실기기·UWB 없이: mock.simulateEnter(...) → SDK가 floors 로드하는지,
//  simulateZone(...) → events/zone 나가는지, simulatePosition(...) → 버퍼→벌크 나가는지.
//

import Foundation

@MainActor
public final class MockPositioningProvider: PositioningProvider {

    public weak var delegate: PositioningProviderDelegate?
    public private(set) var isRunning = false

    /// apply()로 주입받은 config (테스트 검증용)
    public private(set) var appliedBuildingId: String?
    public private(set) var appliedFloorId: String?

    public init() {}

    /// start() 가 불린 횟수 — 코어가 엔진을 다시 켰는지 테스트가 본다.
    public private(set) var startCount = 0
    /// 다음 start() 를 그 자리에서 접는다 — 실제 엔진의 「라이선스 없음·위치 권한 이미 거부」 처럼 동기로.
    public var failNextStartSynchronously: Bool? = nil   // nil = 정상, true/false = retryable 값으로 접힘
    public func start() {
        startCount += 1
        if let retryable = failNextStartSynchronously {
            failNextStartSynchronously = nil
            delegate?.provider(self, didStopUnexpectedly: retryable, context: "mock sync")
            return
        }
        isRunning = true
    }
    public func stop() { isRunning = false }

    /// 일시정지 — 실제 엔진처럼 start()/stop() 을 건너도 유지된다.
    public private(set) var isPaused = false
    public func pause() { isPaused = true }
    public func resume() { isPaused = false }

    /// 엔진이 스스로 꺼졌다(시작이 접혔거나 엔진 오류) — 실제 엔진이 하는 것처럼 꺼진 뒤 코어에 알린다.
    public func simulateUnexpectedStop(retryable: Bool, context: String = "mock") {
        isRunning = false
        delegate?.provider(self, didStopUnexpectedly: retryable, context: context)
    }

    /// 코어가 "영역이 바뀌었다" 고 판단한 횟수 — 테스트가 이 값을 본다.
    public private(set) var reloadGeofencesCount = 0
    public func reloadGeofences() { reloadGeofencesCount += 1 }

    public func apply(buildingId: String, floorId: String) {
        appliedBuildingId = buildingId
        appliedFloorId = floorId
    }

    /// apply(config:) 가 불린 횟수와 마지막 값 — 코어가 판정기를 다시 물렸는지 테스트가 본다.
    public private(set) var applyConfigCount = 0
    public private(set) var lastConfig: PositioningConfig?
    public func apply(config: PositioningConfig) {
        applyConfigCount += 1
        lastConfig = config
    }

    // MARK: - 시뮬레이션 트리거 (테스트·데모가 호출)

    /// 빌딩 입장 발생
    public func simulateEnter(buildingId: String) {
        delegate?.provider(self, didEnter: buildingId)
    }

    /// 좌표 fix 발생
    public func simulatePosition(_ c: Coordinates, floorId: String, at: Date = Date()) {
        delegate?.provider(self, didUpdate: c, floorId: floorId, at: at)
    }

    /// 엔진이 층을 잡음(nil = 잃음)
    public func simulateFloorDetected(_ floorId: String?) {
        delegate?.provider(self, didDetectFloor: floorId)
    }

    /// 앱에 보일 구역 이벤트 발생(진입·이탈·체류)
    public func simulateZoneEvent(_ event: ZoneEvent) {
        delegate?.provider(self, didEmit: event)
    }

    /// 존 판정 발생
    public func simulateZone(_ zoneId: String, status: ZoneEventStatus,
                             floorId: String, at: Date = Date()) {
        delegate?.provider(self, didDetectZone: zoneId, status: status, floorId: floorId, at: at)
    }
}
