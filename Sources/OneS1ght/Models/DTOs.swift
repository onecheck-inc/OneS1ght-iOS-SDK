//
//  DTOs.swift
//  서버 계약 데이터 구조 — sdk-v1-사양서 §7.1 그대로 (유일한 근거)
//
//  프로퍼티명 = snake_case: 서버 JSON과 1:1이라 CodingKeys 불필요 (사양서 방침).
//  여기는 "데이터 모양"만 — 통신은 Networking/, 조립은 Runtime/ 담당.
//  ⚠️ 고객에게 보이는 것은 Coordinates·ZoneEventStatus·Trigger 셋뿐이다. 요청·응답 봉투는 internal —
//     public 이면 고객이 ApiClient 로 SDK 를 우회할 수 있고, 내부를 바꿀 때마다 고객 코드가 깨진다
//     (2026-10-02 감사 K4 — 0.1.24 까지는 전부 public 이었다).
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

/// POST /auth/verify — 키 검증 + 클라 등록 (초기화 1회)
struct ReqVerify: Codable {
    let platform_name: String        // "iOS"
    var app_id: String?
}

/// POST /events/zone — 존 입장/체류/퇴장 (판정 시마다)
struct ReqZoneEvent: Codable {
    let profile_id: String
    let visitor_id: String
    let floor_id: String
    let zone_id: String
    let status: ZoneEventStatus
    let occurred_at: String          // 판정 발생 시각 (ISO-8601, 점마다 캡처)
    let platform_name: String
}

/// /positioning/logs 의 points[] 요소
struct PositionPoint: Codable {
    let floor_id: String
    let coordinates: Coordinates
    let captured_at: String          // 점마다 필수 (동선 순서·속도 복원)
}

/// POST /positioning/logs — 좌표 벌크 (봉투 1회 + points[] 반복, 요청당 ≤500)
struct ReqPositionBulk: Codable {
    let profile_id: String
    let visitor_id: String
    let platform_name: String
    let points: [PositionPoint]
}

// MARK: - 프로필 (서버 TBD — SDK 가 계약을 정의한다)

/// POST /profiles 요청 — 속성은 고객사 자유 (성별·연령대·관심사 등).
/// ⚠️ 재식별 방지를 위해 나이는 정확값이 아니라 연령대("20s")로 받도록 안내한다.
struct ReqProfile: Codable {
    let attributes: [String: String]
    init(attributes: [String: String]) { self.attributes = attributes }
}

/// POST /profiles 응답 — 서버가 profileId 를 발급한다.
/// 고객사 회원 ID ↔ profile_id 매핑은 고객사만 보관 — 회원 ID 는 OneS1ght 에 오지 않는다.
struct ResProfileCreate: Codable {
    let profile_id: String

    /// id 는 숫자로 와도 받는다(S17). 아예 없으면 발급 실패라 던진다 — 빈 id 로 넘어가면 안 된다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientID(.profile_id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.profile_id, .init(
                codingPath: c.codingPath, debugDescription: "profile_id 가 없습니다"))
        }
        profile_id = id
    }
}

/// GET·PUT /profiles/{id} 응답
struct ResProfile: Codable {
    let profile_id: String?
    /// 속성 자루 — 값 종류가 섞여 와도(숫자·불리언) 문자열로 접어 읽는다(S17).
    let attributes: [String: String]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile_id = c.lenientID(.profile_id)
        attributes = (try? c.decode(LenientStringMap.self, forKey: .attributes))?.values
    }
}

/// DELETE /profiles/{id} 응답
struct ResProfileDelete: Codable {
    let deleted: Bool
}

// MARK: - SDK 로그 (관리자가 콘솔 로그 분석기에서 본다)

/// 로그 한 줄. **문구가 아니라 코드를 보낸다** — 사람이 읽는 문장은 콘솔이
/// 관리자 화면 언어로 렌더링한다(로그를 읽는 사람은 기기 사용자가 아니다).
struct SdkLogEntry: Codable {
    let code: String          // E1001 · I3001 …
    let level: String         // ERROR · WARN · INFO
    let message: String       // 문맥만 (floor=… building=…). 개인정보·키 금지
    let at: String            // ISO-8601 (UTC, 밀리초)
}

/// POST /logs — 요청당 최대 500건 (초과 시 422)
struct ReqSdkLogs: Codable {
    let profile_id: String
    let platform_name: String
    let sdk_version: String
    let entries: [SdkLogEntry]
}

struct ResSdkLogs: Codable {
    /// 서버가 빼거나 타입을 바꿔도 200 은 성공이다 — 그래서 옵셔널로 관대하게 읽는다(S17).
    let accepted_count: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted_count = c.lenient(Int.self, .accepted_count)
    }
}

// MARK: - 응답 (서버 → SDK)

/// POST /auth/verify 응답
struct ResVerify: Codable {
    let valid: Bool
    let tenant_code: String?
    let positioning_enabled: Bool    // false면 측위 시작 안 함
    /// 초당 좌표 전송 횟수 (1~100). 테넌트 단위 설정 — 어드민 /admin/sdk 에서 조정.
    /// 구서버는 이 필드를 안 주므로 옵셔널. 없거나 범위 밖이면 SdkDefaults.positionRateHz.
    let position_rate_hz: Int?
    /// SDK 키별 원격 설정 (environment · logLevel 등). 앱 재배포 없이 서버가 제어.
    ///
    /// ⚠️ **이 필드 때문에 초기화가 실패해서는 안 된다.** 서버가 마음대로 늘리는 자루이고,
    /// SDK 는 아직 이 값을 읽지도 않는다. 그런데 2026-08-21 에 서버가 정수·불리언을 담자
    /// `[String: String]` 디코드가 깨지면서 **이미 배포된 앱의 initialize 가 전부 실패**했다.
    /// 그래서 아래 init 에서 이 항목만 최선노력으로 읽는다 — 못 읽으면 nil 로 두고 넘어간다.
    let remote_config: [String: String]?

    init(valid: Bool, tenant_code: String?, positioning_enabled: Bool,
                position_rate_hz: Int?, remote_config: [String: String]?) {
        self.valid = valid
        self.tenant_code = tenant_code
        self.positioning_enabled = positioning_enabled
        self.position_rate_hz = position_rate_hz
        self.remote_config = remote_config
    }

    init(from decoder: Decoder) throws {
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
enum SdkDefaults {
    static let positionRateHz = 4
    static let minRateHz = 1
    static let maxRateHz = 100
}

/// 콘솔이 내려주는 관련 키 — SDK 키 하나로 받는다.
///
/// ⚠️ **전부 옵셔널이다.** 서버는 채우지 못한 키를 null 로 두고 200 을 준다(부분 실패).
/// 하나를 필수로 만들면 그 키가 빈 테넌트에서 초기화가 통째로 실패한다 —
/// 2026-08-21 의 remote_config 사고와 같은 모양이다.
///
/// ⚠️ internal 까지만(M1) — 이 타입이 public 이면 공간 서비스 모바일 키를 앱이 직접 꺼낼 길이 열린다.
/// 앱에 내줄 값은 `OneS1ght.googleMapKey` 하나뿐이다(지도 SDK 에 앱이 직접 넣어야 하는 값).
struct ResSdkConfig: Codable {
    let tenant_code: String?
    let google_map_key: String?
    let geo_sdk_key: String?
    let geo_partner_key: String?
    let geo_base_url: String?

    init(tenant_code: String? = nil, google_map_key: String? = nil,
         geo_sdk_key: String? = nil, geo_partner_key: String? = nil,
         geo_base_url: String? = nil) {
        self.tenant_code = tenant_code
        self.google_map_key = google_map_key
        self.geo_sdk_key = geo_sdk_key
        self.geo_partner_key = geo_partner_key
        self.geo_base_url = geo_base_url
    }
}

/// 서버가 존 이벤트에 맞춰 돌려준 개인화 액션(쿠폰·사이니지 등) — `FloorSession.onTriggers` 로 온다.
public struct Trigger: Codable, Equatable {
    /// 액션 ID. 서버가 숫자로 주어도 문자열로 받는다. 서버가 빼면 빈 문자열.
    public let triggerId: String
    /// 액션 종류 — `signage` · `coupon` · `tracking` · `merch` · `generic`.
    /// ⚠️ 문자열이다 — 서버가 종류를 늘릴 수 있어 모르는 값도 그대로 온다. 서버가 빼면 `generic`.
    public let type: String
    /// 액션 내용(title·rule 등). 서버 선언이 느슨한 자루라 **여기서 실패하면 안 된다.**
    ///
    /// ⚠️ `remote_config` 와 완전히 같은 구조다. 쿠폰 금액(숫자)이나 다국어 블록을 하나 얹는 순간
    /// 존 이벤트 응답 **전체** 디코드가 깨지면 이미 배포된 앱에서 쿠폰·사이니지가 조용히 끊기고,
    /// 측위는 그대로 돌아서 초기화 실패보다 오히려 발견이 늦다. 그래서 값은 문자열로 접어 읽는다.
    public let payload: [String: String]?

    public init(triggerId: String, type: String, payload: [String: String]?) {
        self.triggerId = triggerId
        self.type = type
        self.payload = payload
    }

    /// 0.1.24 까지의 이름 — 서버 필드 이름(snake_case)이 그대로 드러나 있었다(2026-10-02 감사 K13).
    @available(*, deprecated, renamed: "triggerId")
    public var trigger_id: String { triggerId }

    @available(*, deprecated, renamed: "init(triggerId:type:payload:)")
    public init(trigger_id: String, type: String, payload: [String: String]?) {
        self.init(triggerId: trigger_id, type: type, payload: payload)
    }

    /// 서버 계약(JSON) 이름은 그대로다 — Swift 이름만 바꿨다.
    private enum CodingKeys: String, CodingKey {
        case triggerId = "trigger_id", type, payload
    }

    /// ⚠️ 관대하게 읽는다(S17). id 가 숫자로 와도, 빠져도 트리거는 산다 — 쿠폰을 그리는 데 필요한
    ///    것은 payload 다. type 이 빠지면 "generic" 으로 본다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggerId = c.lenientID(.triggerId) ?? ""
        type = c.lenient(String.self, .type) ?? "generic"
        payload = (try? c.decode(LenientStringMap.self, forKey: .payload))?.values
    }
}

/// POST /events/zone 응답.
///
/// ⚠️ 원소 단위로 관대하게 읽는다(S17). 예전엔 event_id 가 숫자·null 이거나 트리거 하나가 틀리면
///    응답 전체가 디코드 실패 → 그 존 이벤트의 쿠폰이 **전부** 조용히 사라졌다.
struct ResZoneEvent: Codable {
    let accepted: Bool
    let event_id: String?
    let triggers: [Trigger]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = c.lenient(Bool.self, .accepted) ?? true     // 200 이면 받은 것이다
        event_id = c.lenientID(.event_id)
        triggers = c.lossyArray(Trigger.self, .triggers)
    }
}

/// POST /positioning/logs 응답
///
/// ⚠️ accepted_count 를 엄격하게 읽으면 서버가 이 필드를 빼거나 타입을 바꾸는 순간 **200 을 실패로**
///    읽어 같은 좌표를 다시 보냈다(S17). 이 값은 로그에만 쓴다.
struct ResPositionBulk: Codable {
    let accepted_count: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted_count = c.lenient(Int.self, .accepted_count)
    }
}
