//
//  ZoneEngine.swift
//  도면 로컬 좌표 기반 Zone 판정 — 순수 수학 (플랫폼 의존성 0)
//
//  iOS 네이티브 지오펜싱(CLCircularRegion)은 GPS 실외·원형 전용이라 안 쓰고,
//  point-in-polygon(ray casting)으로 직접 판정한다.
//
//  디바운스(2026-07-18 확정): 1초에 1번 판단, N(=3)연속 같은 판정이어야 IN/OUT 확정.
//  경계선 좌표 지터(깜빡임)를 카운터 리셋 방식으로 흡수한다.
//

import Foundation

/// 도면 로컬 좌표 (미터 단위, 좌하단 원점).
public struct Position: Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 폴리곤 하나로 정의되는 구역.
public struct Zone: Identifiable {
    public let id: String
    public let name: String
    public let polygon: [Position]     // 꼭짓점 (순서대로)

    // 판정 파라미터 — 콘솔 존 메타(§6.4)와 1:1, PRM 엔진이 소비 (자체 엔진은 폴리곤만 사용)
    public let inDist: Double          // 진입 판단 거리(m)
    public let inCount: Int            // 진입 확정 감지 횟수
    public let inCountInterval: Int    // 감지 카운트 간격(초)
    public let outPeriod: Int          // 이탈 판정 유예
    public let priority: Int           // 영역 겹칠 때 우선순위
    public let callInout: Bool         // 진출입 콜백 발행 여부
    public let dwellSeconds: Int?      // 체류 발화 주기(초) — nil 이면 기본 5초

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

/// 1초 판단 1회의 스냅샷 (디버그 로그용).
public struct ZoneJudge {
    public let position: Position
    public let insideZone: String?   // 지금 "안"에 있는 zone 이름 (nil = 밖)
    public let inStreak: Int         // 진입 연속 카운트
    public let outStreak: Int        // 이탈 연속 카운트
    public let activeZone: String?   // 확정된 활성 zone (nil = OUT 상태)
}

/// 존 판정 엔진 계약 — 좌표를 넣으면 IN/DWELL/OUT 이벤트가 나온다.
/// 구현: PrmZoneEngine(iOS 실전 — Geoplan PRM) / ZoneEngine(자체 — 맥 테스트·폴백)
@MainActor
public protocol ZoneJudging: AnyObject {
    var zones: [Zone] { get }
    var onEvent: ((ZoneEvent) -> Void)? { get set }
    var onJudge: ((ZoneJudge) -> Void)? { get set }
    func apply(zones: [Zone])
    func ingest(_ p: Position, now: Date)   // now = 판단 시각 주입 (테스트용 시계)
    func reset()
}

/// 좌표 스트림을 받아 Zone 이벤트로 변환. 카운트 디바운스로 지터를 흡수한다.
@available(iOS 17.0, *)
@MainActor
@Observable
public final class ZoneEngine: ZoneJudging {
    public private(set) var zones: [Zone]
    public private(set) var current: Position?
    public private(set) var activeZoneID: String?     // 현재 "확정된" 구역
    public private(set) var events: [ZoneEvent] = []

    /// 이벤트가 "방금" 확정될 때마다 1회 호출 (toast·쿠폰·서버전송 훅).
    public var onEvent: ((ZoneEvent) -> Void)?

    /// 1초 판단 1회당 호출 (디버그용) — 안/밖, 카운터, 현재 상태를 매 초 관찰.
    public var onJudge: ((ZoneJudge) -> Void)?

    /// 존 목록 교체 (층 전환·폴링으로 늦게 도착). 판정 상태는 버린다 —
    /// 사라진 존의 IN 상태가 남으면 이탈 이벤트가 영영 안 나온다.
    public func apply(zones: [Zone]) {
        self.zones = zones
        reset()
    }

    /// 이벤트 확정 공통 경로 — 누적 + 통지를 한 곳에서.
    private func emit(_ e: ZoneEvent) {
        events.insert(e, at: 0)
        onEvent?(e)
    }

    // 디바운스 파라미터 (현장 튜닝 대상)
    private let confirmCount = 3                      // N연속 같은 판정이어야 IN/OUT 확정 (1초 간격)
    private let sampleInterval: TimeInterval = 1.0    // 1초에 1번만 판단 (geoSDK는 최대 4회/초 방출)
    private let dwellThreshold: TimeInterval = 5.0    // 5초마다 dwell 발화 (5초, 10초, 15초…)

    // 상태 추적
    private var lastJudgedAt: Date?       // 마지막 판단 시각 (1초 throttle)
    private var candidateZoneID: String?  // 진입 카운트 중인 후보 zone
    private var inStreak = 0              // 후보 zone 연속 "안" 횟수
    private var outStreak = 0             // 활성 zone 연속 "밖" 횟수
    private var activeEnteredAt: Date?    // IN 된 시각 (dwell 계산)
    private var dwellCount = 0            // 발화한 dwell 구간 수 (5초마다 +1)

    public init(zones: [Zone]) { self.zones = zones }

    public func reset() {
        current = nil; activeZoneID = nil; events = []
        lastJudgedAt = nil
        candidateZoneID = nil; inStreak = 0; outStreak = 0
        activeEnteredAt = nil; dwellCount = 0
    }

    /// 좌표 1개 투입 → 상태 갱신 + 이벤트 생성.
    /// 판단은 1초에 1번(sampleInterval)만 — 그 사이 들어온 좌표는 current만 갱신하고 버림.
    /// 규칙: "N번 연속 같은 판정"이면 IN/OUT 확정. 중간에 반대가 하나 나오면 카운터 리셋.
    /// (신호 끊긴 초는 ingest 자체가 안 불려 판단 스킵 = 상태 유지 → 오이탈 방지)
    public func ingest(_ p: Position, now: Date = Date()) {
        current = p
        // 1초 throttle — 아직 1초 안 지났으면 판단 안 함
        if let last = lastJudgedAt, now.timeIntervalSince(last) < sampleInterval { return }
        lastJudgedAt = now

        let hit = zones.first { $0.contains(p) }   // 지금 "안"에 있는 zone (없으면 nil)

        // 이 초의 판단 결과를 함수 끝에서 로그로 (모든 return 경로에서 찍힘)
        defer {
            onJudge?(ZoneJudge(position: p, insideZone: hit?.name,
                               inStreak: inStreak, outStreak: outStreak,
                               activeZone: activeZone?.name))
        }

        // ── 활성 zone이 있으면: 이탈 카운트 + dwell ──
        if let active = activeZone {
            if hit?.id == active.id {
                outStreak = 0                       // 활성 zone 안 → 이탈 카운트 리셋
                // dwell — 5초마다 누적 체류시간으로 발화 (5초,10초,15초…)
                if let entered = activeEnteredAt {
                    let due = Int(now.timeIntervalSince(entered) / dwellThreshold)
                    if due > dwellCount {
                        dwellCount = due
                        emit(.dwell(zone: active, seconds: Double(due) * dwellThreshold, at: now))
                    }
                }
                return                              // 활성 zone 안 → 진입 카운트 볼 것 없음
            }
            outStreak += 1                          // 활성 zone 밖 → 이탈 카운트++
            guard outStreak >= confirmCount else { return }   // 아직 미확정 → 유지
            emit(.exit(zone: active, at: now))
            activeZoneID = nil; activeEnteredAt = nil
            outStreak = 0; dwellCount = 0
            // 나간 뒤에도 다른 zone 안일 수 있음 → 아래 진입 카운트로 이어짐
        }

        // ── 활성 zone 없음: 진입 카운트 ──
        if let hit {
            if candidateZoneID == hit.id {
                inStreak += 1
            } else {
                candidateZoneID = hit.id; inStreak = 1   // 새 후보 → 1부터
            }
            if inStreak >= confirmCount {
                activeZoneID = hit.id
                activeEnteredAt = now
                dwellCount = 0
                emit(.enter(zone: hit, at: now))
                candidateZoneID = nil; inStreak = 0
            }
        } else {
            candidateZoneID = nil; inStreak = 0          // 밖 → 진입 후보 리셋
        }
    }

    private var activeZone: Zone? { zones.first { $0.id == activeZoneID } }
}
