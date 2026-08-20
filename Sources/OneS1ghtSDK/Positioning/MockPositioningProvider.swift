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

    public func start() { isRunning = true }
    public func stop() { isRunning = false }

    public func apply(buildingId: String, floorId: String) {
        appliedBuildingId = buildingId
        appliedFloorId = floorId
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

    /// 존 판정 발생
    public func simulateZone(_ zoneId: String, status: ZoneEventStatus,
                             floorId: String, at: Date = Date()) {
        delegate?.provider(self, didDetectZone: zoneId, status: status, floorId: floorId, at: at)
    }
}
