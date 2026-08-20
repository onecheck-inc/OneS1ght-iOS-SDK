//
//  PositioningProvider.swift
//  측위 엔진 주입 계약 — SDK는 UWB를 모른다 (프롬프트 결정사항 2, 시그니처 그대로)
//
//  실제 구현(호스트 쪽): NISession + gpi-dltdoa + ZoneEngine을 감싼 어댑터가
//  이 프로토콜을 채택해 콜백 3종을 쏜다. 패키지는 그 결과를 서버 계약에 맞춰 전송만.
//
//  ⚠️ iOS의 UWB(Nearby Interaction)는 포그라운드 전용 — 백그라운드 전환 시
//     SessionCoordinator가 pause+flush, 복귀 시 재개한다 (결정사항 6).
//

import Foundation

/// 측위 설정 — 측위 엔진에 주입하는 "콘센트".
///
/// ★ 소스 갈아끼우는 자리: **지금은 앱(Geospace3Client)이 GeoSpace에서 받아 채워 넣고**,
///   나중에 console 이 도면·앵커·존을 프록시하면 **그쪽에서 받아 같은 자리에 꽂는다.**
///   소스(앱 GeoSpace ↔ 서버 프록시)가 바뀌어도 이 구조체와 apply(config:)는 고정.
public struct PositioningConfig {
    /// 앵커: 짧은주소(UWB MAC 뒤 2바이트, 예: 0xABCD) → 도면 로컬 미터 좌표
    public let anchors: [Int: SIMD3<Double>]
    /// UWB 세션(= networkIdentifier). 층마다 다름
    public let sessionId: Int?
    /// 이 층의 존 — 온디바이스 판정 대상 (비면 판정이 돌지 않는다)
    public let zones: [Zone]
    public init(anchors: [Int: SIMD3<Double>] = [:], sessionId: Int? = nil, zones: [Zone] = []) {
        self.anchors = anchors
        self.sessionId = sessionId
        self.zones = zones
    }
}

@MainActor
public protocol PositioningProvider: AnyObject {
    var delegate: PositioningProviderDelegate? { get set }
    func start()
    func stop()

    /// 서버 config 반영 (선택 채택 — 기본 no-op).
    /// SDK 코어가 GET /positioning/buildings 응답에서 건물·층을 뽑아 넣어준다.
    func apply(buildingId: String, floorId: String)

    /// 측위 설정(앵커·세션) 주입 (선택 채택 — 기본 no-op).
    /// ★ 소스 무관 통로 — 앱이 GeoSpace/서버에서 받은 값을 여기로 꽂는다. start 전에 호출.
    func apply(config: PositioningConfig)
}

public extension PositioningProvider {
    func apply(buildingId: String, floorId: String) {}   // 기본: 무시 (Mock 등)
    func apply(config: PositioningConfig) {}              // 기본: 무시
}

@MainActor
public protocol PositioningProviderDelegate: AnyObject {
    /// 좌표 갱신(측위 fix) — SDK가 버퍼링 → positioning/logs
    func provider(_ p: PositioningProvider, didUpdate coordinates: Coordinates,
                  floorId: String, at capturedAt: Date)
    /// 존 진입/체류/이탈 판정 — SDK가 events/zone 전송
    func provider(_ p: PositioningProvider, didDetectZone zoneId: String,
                  status: ZoneEventStatus, floorId: String, at occurredAt: Date)
    /// 입장 트리거(빌딩 진입 감지) — SDK가 buildings/floors 로드 시작
    func provider(_ p: PositioningProvider, didEnter buildingId: String)
}
