//
//  PrmZoneEngine.swift
//  OneS1ght
//
//  Geoplan PRM(gpi-prm) 기반 존 판정 — iOS 실전 엔진.
//  · 콘솔 존 API의 판정 파라미터(in_dist·in_count·out_period 등)를 그대로 소비한다
//    — 자체 ZoneEngine 은 폴리곤만 쓰고 파라미터를 무시했던 것을 이걸로 해소.
//  · PRM 은 IN/OUT 만 준다 → DWELL 은 dwell_seconds 설정된 존에서만, 도달 시점에 1회 파생.
//    (반복 발화 금지 — 서버 시책 매칭에 중복 억제가 없어 반복 전송은 트리거 도배가 된다)
//  · AreaInfo 에는 ID 필드가 없다 → name 을 매핑 키로 쓴다 (중복 시 #n 접미사로 유일화).
//  · PRM 콜백은 백그라운드 큐 → 메인으로 디스패치해 onEvent 발행.
//  · PRM 2.0.0 부터 인스턴스 단위(Prm.create) — 층 전환(apply)마다 stop → start 로 존 교체.
//
//  2026-09-09 엔진(gpi-ihub)으로 바꾸면서 뺐다가, 2026-09-30 직접 선택 모드(PositioningMode.manual)
//  때문에 되살렸다. 자동 모드는 엔진이 안에서 같은 PRM 을 돌리고 IN/OUT 만 준다(UwbAreaJudge 가 받는다).
//  직접 선택 모드는 엔진이 없으므로 SDK 가 이 판정기를 직접 돌린다 — 콘솔 존 파라미터가 두 모드에서
//  같은 규칙으로 소비된다. 엔진이 시리얼 모드 시작 API 를 내주면 이 파일은 다시 빠질 수 있다.
//

#if os(iOS)

import Foundation
import CoreGraphics
import gpi_prm

@MainActor
final class PrmZoneEngine {

    private(set) var zones: [Zone] = []
    var onEvent: ((ZoneEvent) -> Void)?
    var onLog: ((LogLevel, String) -> Void)?   // PRM 수명주기·오류 진단 (조용한 실패 금지)

    /// PRM 인스턴스 이름 — 엔진 파일로그(gpi-logger)와 콜백의 prmName 으로 나오는 식별용.
    /// 기기 단위 익명 ID 를 없앴으므로 고정값을 쓴다. 인스턴스는 기기당 하나뿐이라
    /// 구분이 필요 없고, 서버 데이터와의 대조는 profile_id·visitor_id 로 한다.
    private static let prmName = "onesight"
    private let prm: Prm
    private let bridge: CallbackBridge
    private var nameToZone: [String: Zone] = [:]

    // DWELL 파생 상태
    private var activeZoneId: String?
    private var dwellTask: Task<Void, Never>?
    private var warnedNotRunning = false

    // 불가능 조합 감지 — 실측 좌표 주기로 "창 용량 < 확정 횟수"를 판별해 경고 (조용한 침묵 방지)
    private var ingestStamps: [Date] = []
    private var warnedInfeasible = false

    // MARK: - 판정 파라미터 기본값
    // 콘솔에서 값을 설정하지 않으면 0 으로 내려오는데, PRM 에 0 을 그대로 주면 판정이 죽는다.
    // 그때 대신 쓰는 값 — "걸어 들어가면 곧바로 IN" 이 되는 무난한 조합.
    static let defaultInDist: Double        = 3.0   // 이동 게이트 — 보행(0.35m/샘플)·튐(0.34m)을 넉넉히 통과
    static let defaultInCount: Int          = 1     // 존 안 첫 좌표에 IN
    static let defaultInCountInterval: Int  = 1     // 초 (확정 1 회면 실질 미사용)
    static let defaultOutPeriod: Int        = 10    // 신호 끊김 시 10 초 후 OUT
    static let defaultPriority: Int         = 1

    init() {
        // prm 이 stored property 라 self 사용 전에 채워야 한다 → bridge 를 지역에서 먼저 만든다.
        let bridge = CallbackBridge()
        self.bridge = bridge
        self.prm = Prm.create(name: Self.prmName, callback: bridge)
        bridge.owner = self
    }

    // MARK: - 판정기 창구 (UwbAreaJudge 와 같은 모양)

    func apply(zones: [Zone]) {
        self.zones = zones
        if prm.isRunning() { prm.stop() }
        reset()

        nameToZone = [:]
        var areas: [AreaInfo] = []
        for z in zones {
            // name = 매핑 키 (AreaInfo 에 id 가 없음) — 중복이면 #2, #3… 로 유일화
            var key = z.name
            var n = 2
            while nameToZone[key] != nil { key = "\(z.name)#\(n)"; n += 1 }
            nameToZone[key] = z

            // 미설정(0) 필드는 기본값으로 대체 — 콘솔의 0 은 "설정 안 함"이지만
            // PRM 은 그대로 받으면 판정이 죽는다: 확정 0·간격 0 은 무발화, 거리 0 은 0.01m 치환이라
            // 정지 지터(0.05~0.09m)에도 매번 리셋된다 (08-11 실측). 원본 Zone 은 두고 주입값만 보정.
            let a = AreaInfo.Builder(name: key, points: z.polygon.map { CGPoint(x: $0.x, y: $0.y) })
                .inDist(z.inDist > 0 ? z.inDist : Self.defaultInDist)
                .inCount(z.inCount > 0 ? z.inCount : Self.defaultInCount)
                .inCountInterval(z.inCountInterval > 0 ? z.inCountInterval : Self.defaultInCountInterval)
                .outPeriod(z.outPeriod > 0 ? z.outPeriod : Self.defaultOutPeriod)
                .priority(z.priority > 0 ? z.priority : Self.defaultPriority)
                .callInout(z.callInout)
                .build()
            areas.append(a)
        }
        warnedNotRunning = false
        ingestStamps = []
        warnedInfeasible = false
        for z in zones {
            var filled: [String] = []
            if z.inDist <= 0           { filled.append(SdkLocalized.format("zone.defaultInDist", "\(Self.defaultInDist)")) }
            if z.inCount <= 0          { filled.append(SdkLocalized.format("zone.defaultInCount", Self.defaultInCount)) }
            if z.inCountInterval <= 0  { filled.append(SdkLocalized.format("zone.defaultInterval", Self.defaultInCountInterval)) }
            if z.outPeriod <= 0        { filled.append(SdkLocalized.format("zone.defaultOutPeriod", Self.defaultOutPeriod)) }
            if z.priority <= 0         { filled.append(SdkLocalized.format("zone.defaultPriority", Self.defaultPriority)) }
            if !filled.isEmpty {
                onLog?(.log, SdkLocalized.format("zone.defaultsApplied", z.name, filled.joined(separator: " · ")))
            }
        }
        guard !areas.isEmpty else { return }
        // 주입 파라미터 증적 — 콘솔 값이 PRM 까지 실제로 도달했는지 파일로 확인
        for z in zones {
            onLog?(.log, String(format: SdkLocalized.text("zone.paramDump"),
                          z.name, z.inDist, z.inCount, z.inCountInterval, z.outPeriod))
        }
        prm.start(areaInfoList: areas)
    }

    func ingest(_ p: Position, now: Date = Date()) {
        guard prm.isRunning() else {
            if !warnedNotRunning {
                warnedNotRunning = true
                // 예전엔 "존 미주입 또는 start 실패" 한 줄이라, 읽는 사람이 둘 중 어느
                // 쪽인지 알 수 없었다. 둘은 할 일이 완전히 다르다 — 앞은 콘솔에서 구역을
                // 그리면 되고, 뒤는 엔진 문제라 신고 대상이다. 실제 값으로 갈라 말한다.
                // 등급도 갈라진다 — 구역이 없는 건 정상 상태(info)이고,
                // 넣었는데 엔진이 안 선 건 고장(error)이다.
                if zones.isEmpty {
                    onLog?(.info, SdkLocalized.text("zone.noZones"))
                } else {
                    onLog?(.error, SdkLocalized.format("zone.startFailed", zones.count))
                }
            }
            return
        }
        if !warnedInfeasible {
            ingestStamps.append(now)
            if ingestStamps.count == 20 {
                warnedInfeasible = true          // 검사는 세션당 1회
                // 집계간격 = 연속 감지로 인정되는 최대 공백(초). 좌표 주기가 이보다 크면
                // 카운트가 매번 리셋돼 IN 이 영원히 안 난다 (실측 확정, 08-05).
                let gap = ingestStamps[19].timeIntervalSince(ingestStamps[0]) / 19.0
                for z in zones where z.inCount >= 2 {
                    if Double(z.inCountInterval) <= gap {
                        onLog?(.warn, String(format: SdkLocalized.text("zone.intervalTooShort"),
                                      z.name, z.inCountInterval, gap))
                    } else {
                        onLog?(.log, String(format: SdkLocalized.text("zone.confirmEstimate"),
                                      z.name, z.inCount, Double(z.inCount) * gap, gap))
                    }
                }
            }
        }
        prm.pushEvent(x: p.x, y: p.y, z: 0)
    }

    func reset() {
        dwellTask?.cancel()
        dwellTask = nil
        activeZoneId = nil
    }

    /// 지금 안에 있는 구역에서 나간 것으로 친다 — EXIT 한 번을 내고 판정 상태를 비운다.
    /// 배경 전환 직전에 쓴다(UwbAreaJudge.exitActive 와 같은 이유·같은 순서 — 상태를 먼저 비운다).
    func exitActive(at: Date = Date()) {
        guard let id = activeZoneId, let zone = zones.first(where: { $0.id == id }) else {
            reset()
            return
        }
        reset()
        onEvent?(.exit(zone: zone, at: at))
    }

    /// 판정기 정지 — 직접 선택 모드 측위를 끌 때(stopManual). 존 목록은 남겨 두어 다음 시작 때
    /// apply(zones:) 가 그대로 다시 넣는다. 안 돌고 있으면 아무 일도 없다(PRM 은 정지 중 stop 을
    /// onError 로 통지하므로 여기서 거른다).
    func stop() {
        reset()
        if prm.isRunning() { prm.stop() }
    }

    // MARK: - PRM 이벤트 (메인 큐에서 호출됨 — bridge 가 디스패치)

    fileprivate func handleInout(_ io: String, areaName: String) {
        guard let zone = nameToZone[areaName] else { return }
        let now = Date()
        switch io {
        case "IN":
            activeZoneId = zone.id
            onEvent?(.enter(zone: zone, at: now))
            startDwell(zone: zone)
        case "OUT":
            if activeZoneId == zone.id { reset() }
            onEvent?(.exit(zone: zone, at: now))
        default:
            break
        }
    }

    /// DWELL 파생 — 체류시간(dwell_seconds) 도달 시 1회 발화 (콘솔 "체류 트리거" 의미 그대로).
    /// dwell_seconds 미설정 존(enter/exit 트리거)은 DWELL 이벤트를 만들지 않는다.
    private func startDwell(zone: Zone) {
        dwellTask?.cancel()
        guard let seconds = zone.dwellSeconds, seconds > 0 else { return }
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard let self, self.activeZoneId == zone.id, !Task.isCancelled else { return }
            self.onEvent?(.dwell(zone: zone, seconds: TimeInterval(seconds), at: Date()))
        }
    }

    /// PRM 콜백 수신자 — 백그라운드 큐에서 불리므로 메인으로 넘겨 엔진에 전달.
    /// (PrmCallback 이 AnyObject 요구라 엔진 본체와 분리 — retain cycle 도 회피)
    private final class CallbackBridge: PrmCallback {
        weak var owner: PrmZoneEngine?
        func onStart(prmName: String) { relay("▶︎ PRM start") }
        func onStop(prmName: String)  { relay("■ PRM stop") }
        func onError(prmName: String, msg: String) { relay("⚠️ PRM error: \(msg)") }
        private func relay(_ msg: String) {
            Task { @MainActor [weak owner] in owner?.onLog?(.log, msg) }
        }
        func onReceivedInout(prmName: String, inoutStr: String, areaName: String) {
            Task { @MainActor [weak owner] in
                // 원본 콜백 증적 — 어댑터 번역 전 PRM 이 준 그대로 (판정 주체가 PRM 임을 파일로 증명)
                // prmName = 인스턴스 이름 = anon_profile_id (2.0.0 이전의 tagId 자리)
                owner?.onLog?(.log, "PRM ← \(inoutStr) tag=\(prmName) area=\(areaName)")
                owner?.handleInout(inoutStr, areaName: areaName)
            }
        }
    }
}

#endif
