//
//  SpaceModels.swift
//  OneS1ght
//
//  호스트 앱이 "공간을 고르고 지도를 그리기 위해" 받는 타입들.
//  · 데이터 출처(콘솔/GeoSpace)는 SDK 내부 사정이라 타입 이름에 드러내지 않는다.
//  · UI 프레임워크 의존 없음 — 도면은 Data(PNG)로 준다. 렌더링은 앱 몫.
//  · 좌표는 전부 도면 로컬 미터. 측위·존 판정과 같은 좌표계다.
//

import Foundation

/// 건물 — 목록 UI 용.
///
/// 층 목록은 담지 않는다. 필요하면 `floors(buildingID)` 로 따로 받는다 —
/// 층마다 도면 조회가 따라붙어 목록이 무거워지기 때문이다.
public struct Building: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// 층 개수. 목록 화면에서 "3개 층" 같은 표시에 쓴다.
    /// 서버가 아직 이 값을 주지 않으면 nil — 그때는 표시를 생략해야 한다.
    public let floorCount: Int?

    public init(id: String, name: String, floorCount: Int? = nil) {
        self.id = id; self.name = name; self.floorCount = floorCount
    }
}

/// 층 — 선택 UI + 지도 배경.
///
/// ⚠️ `image` 는 `floors(buildingID)` 목록에서 **비어 있다**(nil). 층마다 도면 PNG 를
/// 들고 오면 목록이 수 MB 가 되기 때문이다. 지도를 그릴 때 `floor(buildingID:floorID:)`
/// 로 단건을 받으면 채워져 온다(세션 캐시가 있어 추가 왕복은 없다).
public struct Floor: Identifiable, Equatable {
    public let id: String
    public let name: String

    /// 도면 PNG. 목록 조회에서는 nil.
    public let image: Data?
    /// 도면이 등록된 층인가 — `image` 가 nil 이어도 이 값으로 판단할 수 있다.
    public let hasPlan: Bool

    /// 도면 원점 오프셋 (미터)
    public let originX, originY: Double
    /// 도면 실제 크기 (미터)
    public let widthM, heightM: Double

    /// 도면이 덮는 범위 — 지도 배치(bounds)에 그대로 쓴다
    public var minX: Double { originX }
    public var minY: Double { originY }
    public var maxX: Double { originX + widthM }
    public var maxY: Double { originY + heightM }

    public init(id: String, name: String, image: Data? = nil, hasPlan: Bool = false,
                originX: Double = 0, originY: Double = 0,
                widthM: Double = 0, heightM: Double = 0) {
        self.id = id; self.name = name
        self.image = image; self.hasPlan = hasPlan
        self.originX = originX; self.originY = originY
        self.widthM = widthM; self.heightM = heightM
    }
}

/// 벽에 설치된 측위 로케이터 한 대
public struct Locator: Equatable {
    /// UWB MAC 뒤 2바이트 (예: 0x9DD7)
    public let address: Int
    /// 도면 로컬 미터
    public let x, y, z: Double

    public init(address: Int, x: Double, y: Double, z: Double) {
        self.address = address; self.x = x; self.y = y; self.z = z
    }
}

/// 한 층의 로케이터 묶음.
///
/// `sessionId`(UWB networkIdentifier)는 별도 API 가 아니라 이 응답에 함께 실려 온다.
public struct FloorLocators: Equatable {
    public let locators: [Locator]
    /// UWB 세션(networkIdentifier) — 층마다 다르다. nil 이면 측위 시작 불가.
    public let sessionId: Int?
    /// 로케이터와 세션이 모두 있어 측위를 시도할 수 있는가
    public var positioningReady: Bool { !locators.isEmpty && sessionId != nil }

    public init(locators: [Locator], sessionId: Int?) {
        self.locators = locators; self.sessionId = sessionId
    }
}

// MARK: - 내부

/// 측위·판정에 쓰는 층 상태 — `setFloorMap` 이 만들어 들고 있는다.
/// 도면은 여기 없다(지도는 앱이 `Floor` 로 그린다).
struct FloorState {
    let buildingId: String
    let floorId: String
    let sessionId: Int?
    let locators: [Locator]
    /// 존은 폴링으로 늦게 채워질 수 있어 var
    var zones: [Zone]
}
