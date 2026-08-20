//
//  SpaceModels.swift
//  OneS1ght
//
//  호스트 앱이 "지도를 그리기 위해" 받는 공간 정보 타입들.
//  · 데이터 출처(콘솔/GeoSpace)는 SDK 내부 사정이라 타입 이름에 드러내지 않는다.
//  · UI 프레임워크 의존 없음 — 도면은 Data(PNG)로 준다. 렌더링은 앱 몫.
//  · 좌표는 전부 도면 로컬 미터. 측위·존 판정과 같은 좌표계다.
//

import Foundation

/// 층 (선택 UI용)
public struct SpaceFloor: Identifiable, Equatable {
    public let id: String            // floorId
    public let name: String          // "607호" — 없으면 id 앞자리
    public let hasPlan: Bool         // 도면 등록 여부
    public init(id: String, name: String, hasPlan: Bool) {
        self.id = id; self.name = name; self.hasPlan = hasPlan
    }
}

/// 건물 (선택 UI용)
public struct SpaceBuilding: Identifiable, Equatable {
    public let id: String            // buildingId
    public let name: String
    public let floors: [SpaceFloor]
    public init(id: String, name: String, floors: [SpaceFloor]) {
        self.id = id; self.name = name; self.floors = floors
    }
}

/// 벽에 설치된 측위 앵커 한 대
public struct AnchorPoint: Equatable {
    public let address: Int          // UWB MAC 뒤 2바이트 (예: 0x9DD7)
    public let x, y, z: Double       // 도면 로컬 미터
    public init(address: Int, x: Double, y: Double, z: Double) {
        self.address = address; self.x = x; self.y = y; self.z = z
    }
}

/// 도면 배경 이미지와 실제 치수
public struct FloorPlanImage: Equatable {
    public let pngData: Data
    public let originX, originY: Double    // 도면 원점 오프셋 (미터)
    public let widthM, heightM: Double     // 도면 실제 크기 (미터)

    /// 도면이 덮는 범위 — 지도 배치(bounds)에 그대로 쓴다
    public var minX: Double { originX }
    public var minY: Double { originY }
    public var maxX: Double { originX + widthM }
    public var maxY: Double { originY + heightM }

    public init(pngData: Data, originX: Double, originY: Double, widthM: Double, heightM: Double) {
        self.pngData = pngData
        self.originX = originX; self.originY = originY
        self.widthM = widthM; self.heightM = heightM
    }
}

/// 한 층을 그리고 측위하는 데 필요한 전부.
/// SDK 가 이걸 만들면서 측위 엔진(앵커·세션)과 판정 엔진(존)에도 같은 값을 주입한다.
public struct FloorInfra {
    public let buildingId: String
    public let floorId: String
    /// UWB 세션(networkIdentifier) — 층마다 다르다. nil 이면 측위 시작 불가.
    public let sessionId: Int?
    /// 앵커와 세션이 모두 있어 측위를 시도할 수 있는가
    public let positioningReady: Bool
    public let plan: FloorPlanImage
    public let anchors: [AnchorPoint]
    /// 존은 폴링으로 늦게 채워질 수 있어 var
    public var zones: [Zone]

    public init(buildingId: String, floorId: String, sessionId: Int?, positioningReady: Bool,
                plan: FloorPlanImage, anchors: [AnchorPoint], zones: [Zone]) {
        self.buildingId = buildingId; self.floorId = floorId
        self.sessionId = sessionId; self.positioningReady = positioningReady
        self.plan = plan; self.anchors = anchors; self.zones = zones
    }
}
