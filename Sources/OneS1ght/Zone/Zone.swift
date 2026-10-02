//
//  Zone.swift
//  구역 — 콘솔이 그린 폴리곤과 그 이벤트.
//
//  판정은 측위 엔진이 자기 지오펜스로 한다(UwbAreaJudge 헤더). 여기 타입은 지도 표시·zone_id 매핑·
//  앱 콜백용이다. 예전의 자체 판정기(ZoneEngine·ZoneJudging·ZoneJudge)는 엔진 도입 뒤 아무도 쓰지
//  않아 0.1.24 다음 판에서 지웠다(2026-10-02 감사 K4·K8).
//

import Foundation

/// 도면 로컬 좌표 (미터 단위, 좌하단 원점).
public struct Position: Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 폴리곤 하나로 정의되는 구역.
public struct Zone: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let polygon: [Position]     // 꼭짓점 (순서대로)

    // 판정 파라미터 — 콘솔 존 메타(§6.4)와 1:1. ⚠️ 측위 엔진은 자기 지오펜스로 판정하므로 이 값들은
    // 판정에 쓰이지 않는다(UwbAreaJudge 헤더) — 콘솔 값 그대로 보여 주기만 한다.
    public let inDist: Double          // 진입 판단 거리(m)
    public let inCount: Int            // 진입 확정 감지 횟수
    public let inCountInterval: Int    // 감지 카운트 간격(초)
    public let outPeriod: Int          // 이탈 판정 유예
    public let priority: Int           // 영역 겹칠 때 우선순위
    public let callInout: Bool         // 진출입 콜백 발행 여부
    /// 체류 판정 시간(초) — 진입 뒤 이만큼 머무르면 `onZoneDwell` 이 **한 번** 온다.
    /// `nil`(또는 0 이하)이면 체류 이벤트가 없다 — 진입·이탈만 온다.
    /// (0.1.24 까지 이 주석은 "nil 이면 기본 5초" 라고 했지만 틀렸다 — 2026-10-02 감사 S25.)
    public let dwellSeconds: Int?

    public init(id: String, name: String, polygon: [Position],
                inDist: Double = 3.0, inCount: Int = 0, inCountInterval: Int = 0,
                outPeriod: Int = 0, priority: Int = 1, callInout: Bool = true,
                dwellSeconds: Int? = nil) {
        self.id = id; self.name = name; self.polygon = polygon
        self.inDist = inDist; self.inCount = inCount; self.inCountInterval = inCountInterval
        self.outPeriod = outPeriod; self.priority = priority; self.callInout = callInout
        self.dwellSeconds = dwellSeconds
    }

    /// ray casting — 점이 폴리곤 내부인가.
    public func contains(_ p: Position) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let slope = (p.y - a.y) / (b.y - a.y)
                let xCross = a.x + slope * (b.x - a.x)
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

/// Zone 이벤트.
///
/// ⚠️ 케이스가 늘 수 있다 — `switch` 에는 `@unknown default` 를 둘 것.
public enum ZoneEvent: Identifiable {
    case enter(zone: Zone, at: Date)
    case exit(zone: Zone, at: Date)
    case dwell(zone: Zone, seconds: TimeInterval, at: Date)

    public var id: String {
        switch self {
        case .enter(let z, let t): return "in-\(z.id)-\(t.timeIntervalSince1970)"
        case .exit(let z, let t):  return "out-\(z.id)-\(t.timeIntervalSince1970)"
        case .dwell(let z, let s, let t): return "dw-\(z.id)-\(Int(s))-\(t.timeIntervalSince1970)"
        }
    }

    public var label: String {
        switch self {
        case .enter(let z, _): return "IN  · \(z.name)"
        case .exit(let z, _):  return "OUT · \(z.name)"
        case .dwell(let z, let s, _): return "DWELL · \(z.name) (\(Int(s))s)"
        }
    }
}
