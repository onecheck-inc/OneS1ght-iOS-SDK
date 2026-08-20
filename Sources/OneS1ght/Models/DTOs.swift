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
    ///
    /// ⚠️ **이 필드 때문에 초기화가 실패해서는 안 된다.** 서버가 마음대로 늘리는 자루이고,
    /// SDK 는 아직 이 값을 읽지도 않는다. 그런데 2026-08-21 에 서버가 정수·불리언을 담자
    /// `[String: String]` 디코드가 깨지면서 **이미 배포된 앱의 initialize 가 전부 실패**했다.
    /// 그래서 아래 init 에서 이 항목만 최선노력으로 읽는다 — 못 읽으면 nil 로 두고 넘어간다.
    public let remote_config: [String: String]?

    public init(valid: Bool, tenant_code: String?, positioning_enabled: Bool,
                position_rate_hz: Int?, remote_config: [String: String]?) {
        self.valid = valid
        self.tenant_code = tenant_code
        self.positioning_enabled = positioning_enabled
        self.position_rate_hz = position_rate_hz
        self.remote_config = remote_config
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 측위 가부를 가르는 값이라 여기는 엄격하게 — 없으면 초기화가 실패하는 게 맞다.
        valid = try c.decode(Bool.self, forKey: .valid)
        positioning_enabled = try c.decode(Bool.self, forKey: .positioning_enabled)
        tenant_code = try? c.decode(String.self, forKey: .tenant_code)
        position_rate_hz = try? c.decode(Int.self, forKey: .position_rate_hz)
        // 설정 자루는 실패해도 초기화를 막지 않는다.
        remote_config = (try? c.decode(LenientStringMap.self, forKey: .remote_config))?.values
    }
}

/// 값 종류가 섞인 JSON 객체를 `[String: String]` 으로 접어 읽는다.
///
/// 서버가 돌려주는 설정 자루는 문자열·정수·불리언이 함께 온다. 좁은 타입으로 받으면
/// **항목 하나가 늘 때마다 이미 나간 앱이 깨지므로**, 넓게 받아 문자열로 통일한다.
/// 중첩 객체·배열은 문자열로 옮길 마땅한 표현이 없어 건너뛴다 — 빠뜨려도 초기화는 살아야 한다.
struct LenientStringMap: Decodable {
    let values: [String: String]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: AnyKey.self) else {
            values = [:]                       // 객체가 아니면 빈 설정 — 그래도 초기화는 계속된다
            return
        }
        var out: [String: String] = [:]
        for key in c.allKeys {
            // JSONDecoder 는 이 툴체인에서 엄격하다 — true 가 Int 로, 1 이 Bool 로 넘어오지 않는다(실측).
            if let v = try? c.decode(String.self, forKey: key) { out[key.stringValue] = v }
            else if let v = try? c.decode(Bool.self, forKey: key) { out[key.stringValue] = v ? "true" : "false" }
            else if let v = try? c.decode(Int.self, forKey: key) { out[key.stringValue] = String(v) }
            else if let v = try? c.decode(Double.self, forKey: key) { out[key.stringValue] = String(v) }
        }
        values = out
    }
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
    /// 액션 내용(title·rule 등). 서버 선언이 느슨한 자루라 **여기서 실패하면 안 된다.**
    ///
    /// ⚠️ `remote_config` 와 완전히 같은 구조다. 오늘은 서버가 문자열 2개만 담아서 안 깨지지만,
    /// 쿠폰 금액(숫자)이나 다국어 블록을 하나 얹는 순간 존 이벤트 응답 **전체** 디코드가 깨진다.
    /// 그러면 이미 배포된 앱에서 쿠폰·사이니지가 조용히 끊기고, 측위는 그대로 돌아서
    /// 초기화 실패보다 오히려 발견이 늦다.
    public let payload: [String: String]?

    public init(trigger_id: String, type: String, payload: [String: String]?) {
        self.trigger_id = trigger_id
        self.type = type
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger_id = try c.decode(String.self, forKey: .trigger_id)
        type = try c.decode(String.self, forKey: .type)
        payload = (try? c.decode(LenientStringMap.self, forKey: .payload))?.values
    }
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
