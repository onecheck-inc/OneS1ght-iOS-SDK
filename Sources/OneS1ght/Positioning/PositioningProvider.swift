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

/// 측위 통신 진단 — "등록한 로케이터 중 실제로 몇 대의 신호가 잡히고 있나".
///
/// 플랫폼 중립 형태로 둔 이유는 SessionCoordinator 가 iOS 가드 없이 읽어야 하기 때문이다.
/// UWB 어댑터가 들고 있는 값을 이 모양으로 넘겨준다.
///
/// ⚠️ **이 값만으로 고장을 단정하지 않는다.** 앵커 세트는 마스터 1대와 서브 여러 대로 이루어지고,
/// 마스터가 살아 있는 한 서브가 빠져도 측위는 계속된다 — 감도가 떨어질 뿐이다.
/// 그래서 미수신은 에러가 아니라 **유지보수 신호(WARN)** 로 다룬다.
public struct PositioningDiagnostic: Equatable {
    /// 등록된 로케이터 수
    public let registeredCount: Int
    /// 실제로 신호가 잡힌 수
    public let receivedCount: Int
    /// 등록 ∩ 수신 — 좌표를 아는 유효 로케이터
    public let matchedCount: Int
    /// 등록됐는데 신호가 없는 주소
    public let missingAddresses: [Int]
    /// 측위 엔진이 좌표를 실제로 내고 있는가
    public let hasFix: Bool

    public init(registeredCount: Int, receivedCount: Int, matchedCount: Int,
                missingAddresses: [Int], hasFix: Bool) {
        self.registeredCount = registeredCount
        self.receivedCount = receivedCount
        self.matchedCount = matchedCount
        self.missingAddresses = missingAddresses
        self.hasFix = hasFix
    }

    /// 로그에 실을 한 줄. 주소는 등록된 표기(0xABCD)를 그대로 쓴다 —
    /// 현장에서 기기 라벨과 대조해야 하는 값이라 형식을 바꾸면 못 찾는다.
    public var missingLabel: String {
        missingAddresses.map { String(format: "0x%04X", $0) }.joined(separator: ",")
    }
}

@MainActor
public protocol PositioningProvider: AnyObject {
    var delegate: PositioningProviderDelegate? { get set }
    func start()
    func stop()

    /// 측위 통신 진단 (선택 채택 — 기본 nil).
    /// 진단을 낼 수 없는 provider(Mock 등)는 구현하지 않으면 된다.
    var positioningDiagnostic: PositioningDiagnostic? { get }

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
    var positioningDiagnostic: PositioningDiagnostic? { nil }   // 기본: 진단 없음
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
