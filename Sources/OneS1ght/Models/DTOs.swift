//
//  DTOs.swift
//  서버 계약 데이터 구조 — sdk-v1-사양서 §7.1 그대로 (유일한 근거)
//
//  프로퍼티명 = snake_case: 서버 JSON과 1:1이라 CodingKeys 불필요 (사양서 방침).
//  여기는 "데이터 모양"만 — 로직 0. 통신은 Networking/, 조립은 Runtime/ 담당.
//

import Foundation

// MARK: - 공용

/// 좌표 (미터 — 측위 엔진 원본 단위. 2D면 z=0)
public struct Coordinates: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

/// 존 이벤트 상태 — 서버 표기는 IN/DWELL/OUT
public enum ZoneEventStatus: String, Codable {
    case enter = "IN"
    case dwell = "DWELL"
    case exit  = "OUT"
}

// MARK: - 요청 (SDK → 서버)

/// verify의 client 블록 — 필수는 profile_id뿐, 나머지는 "가진 것만" (생략 시 서버 기존값 보존)
public struct ClientInfo: Codable {
    public let profile_id: String
    public var device_model: String?
    public var os_name: String?
    public var os_version: String?
    public var app_version: String?
    public var sdk_version: String?
    public var device_language: String?
    public var attributes: [String: String]?
}

/// POST /auth/verify — 키 검증 + 클라 등록 (초기화 1회)
public struct ReqVerify: Codable {
    public let platform_name: String        // "iOS"
    public var app_id: String?
    public var client: ClientInfo?
}

/// POST /events/zone — 존 입장/체류/퇴장 (판정 시마다)
public struct ReqZoneEvent: Codable {
    public let profile_id: String
    public let visitor_id: String
    public let floor_id: String
    public let zone_id: String
    public let status: ZoneEventStatus
    public let occurred_at: String          // 판정 발생 시각 (ISO-8601, 점마다 캡처)
    public let platform_name: String
}

/// /positioning/logs 의 points[] 요소
public struct PositionPoint: Codable {
    public let floor_id: String
    public let coordinates: Coordinates
    public let captured_at: String          // 점마다 필수 (동선 순서·속도 복원)
}

/// POST /positioning/logs — 좌표 벌크 (봉투 1회 + points[] 반복, 요청당 ≤500)
public struct ReqPositionBulk: Codable {
    public let profile_id: String
    public let visitor_id: String
    public let platform_name: String
    public let points: [PositionPoint]
}

// MARK: - 프로필 (서버 TBD — SDK 가 계약을 정의한다)

/// POST /profiles 요청 — 속성은 고객사 자유 (성별·연령대·관심사 등).
/// ⚠️ 재식별 방지를 위해 나이는 정확값이 아니라 연령대("20s")로 받도록 안내한다.
public struct ReqProfile: Codable {
    public let attributes: [String: String]
    public init(attributes: [String: String]) { self.attributes = attributes }
}

/// POST /profiles 응답 — 서버가 profileId 를 발급한다.
/// 고객사 회원 ID ↔ profile_id 매핑은 고객사만 보관 — 회원 ID 는 OneS1ght 에 오지 않는다.
public struct ResProfileCreate: Codable {
    public let profile_id: String
}

/// GET·PUT /profiles/{id} 응답
public struct ResProfile: Codable {
    public let profile_id: String
    public let attributes: [String: String]?
}

/// DELETE /profiles/{id} 응답
public struct ResProfileDelete: Codable {
    public let deleted: Bool
}

// MARK: - SDK 로그 (관리자가 콘솔 로그 분석기에서 본다)

/// 로그 한 줄. **문구가 아니라 코드를 보낸다** — 사람이 읽는 문장은 콘솔이
/// 관리자 화면 언어로 렌더링한다(로그를 읽는 사람은 기기 사용자가 아니다).
public struct SdkLogEntry: Codable {
    public let code: String          // E1001 · I3001 …
    public let level: String         // ERROR · WARN · INFO
    public let message: String       // 문맥만 (floor=… building=…). 개인정보·키 금지
    public let at: String            // ISO-8601 (UTC, 밀리초)
}

/// POST /logs — 요청당 최대 500건 (초과 시 422)
public struct ReqSdkLogs: Codable {
    public let profile_id: String
    public let platform_name: String
    public let sdk_version: String
    public let entries: [SdkLogEntry]
}

public struct ResSdkLogs: Codable {
    public let accepted_count: Int
}

// MARK: - 응답 (서버 → SDK)

/// POST /auth/verify 응답
public struct ResVerify: Codable {
    public let valid: Bool
    public let tenant_code: String?
    public let positioning_enabled: Bool    // false면 측위 시작 안 함
    /// 초당 좌표 전송 횟수 (1~100). 테넌트 단위 설정 — 어드민 /admin/sdk 에서 조정.
    /// 구서버는 이 필드를 안 주므로 옵셔널. 없거나 범위 밖이면 SdkDefaults.positionRateHz.
    public let position_rate_hz: Int?
    /// SDK 키별 원격 설정 (environment · logLevel 등). 앱 재배포 없이 서버가 제어.
    public let remote_config: [String: String]?
}

/// 서버가 값을 주지 않을 때 쓰는 기본값 — 종전 SDK 하드코딩과 같아 동작이 바뀌지 않는다.
public enum SdkDefaults {
    public static let positionRateHz = 4
    public static let minRateHz = 1
    public static let maxRateHz = 100
}

/// GET /positioning/buildings 응답
public struct FloorRef: Codable {
    public let floor_id: String             // GeoSpace 층 UUID — 이게 키
    public let name: String                 // 현재 floor_id와 동일 (친화명 추후)
}
public struct BuildingRef: Codable {
    public let building_id: String
    public let name: String
    public let store_id: Int?
    public let floors: [FloorRef]?          // 서버가 생략 가능 → provider 하드코딩 floorId 폴백
}
public struct ResBuildings: Codable {
    public let synced_at: String
    public let buildings: [BuildingRef]
}

/// GET /positioning/floors/{floor_id} 응답 — 존 판정 파라미터 9종
public struct ZoneMeta: Codable {
    public let zone_id: String
    public let name: String
    public let polygon: [[Double]]?         // 미터 좌표 다각형 (⚠️ 실서버 현재 픽셀 이슈)
    public let trigger_type: String
    public let dwell_seconds: Int?
    public let in_dist: Double
    public let in_count: Int
    public let in_count_interval: Int
    public let out_period: Int
    public let priority: Int
    public let call_inout: Bool
    public let is_active: Bool
}
public struct ResFloorConfig: Codable {
    public let floor_id: String
    public let building_id: String?
    public let name: String
    public let synced_at: String
    public let zones: [ZoneMeta]
    public let anchors: [String]            // 현재 항상 [] (GeoSpace 앵커 API 대기)
}

/// POST /events/zone 응답 — triggers = 서버가 매칭한 개인화 액션 (없으면 [])
public struct Trigger: Codable {
    public let trigger_id: String
    public let type: String                 // signage | coupon | tracking | merch | generic
    public let payload: [String: String]?
}
public struct ResZoneEvent: Codable {
    public let accepted: Bool
    public let event_id: String
    public let triggers: [Trigger]
}

/// POST /positioning/logs 응답
public struct ResPositionBulk: Codable {
    public let accepted_count: Int
}
