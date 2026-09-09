//
//  IHubZoneJudge.swift
//  OneS1ght
//
//  gpi-ihub 의 영역 이벤트(onAreaEvent)를 SDK 의 ZoneEvent 로 옮기는 얇은 판정기.
//  PrmZoneEngine 의 후신이다 — 판정 자체를 ihub 가 하므로 좌표를 먹지 않는다.
//
//  종전(PRM)과 같은 점:
//   · IN/OUT 만 온다 → DWELL 은 dwell_seconds 가 설정된 존에서만, 도달 시점에 1회 파생.
//     (반복 발화 금지 — 서버 시책 매칭에 중복 억제가 없어 반복 전송은 트리거 도배가 된다)
//   · 이벤트에 존 ID 가 없다 → **이름을 매핑 키로 쓴다** (중복 시 #n 접미사로 유일화).
//
//  달라진 점 — 읽는 사람이 반드시 알아야 한다:
//   · 콘솔 존의 판정 파라미터(in_dist·in_count·out_period·priority)가 **더 이상 쓰이지 않는다.**
//     PRM 은 그 값을 소비했지만 ihub 는 자기 서버의 지오펜스로 판정한다. 콘솔에서 그 값을
//     바꿔도 판정이 변하지 않는다.
//   · 그래서 콘솔 존은 이제 **지도 표시·zone_id 매핑·서버 전송**을 위해서만 쓰인다.
//   · ihub 영역 이름과 콘솔 존 이름이 어긋나면 이벤트가 버려진다 — 조용히 넘기지 않고
//     경고로 남긴다(ihub.areaUnmapped). 이름이 유일한 연결고리라 여기가 끊기면 시책이 안 돈다.
//

import Foundation

/// ihub 영역 이벤트 → ZoneEvent. 좌표를 받지 않으므로 ZoneJudging 을 채택하지 않는다.
@MainActor
final class IHubZoneJudge {

    /// 지금 물려 있는 콘솔 존 (지도·매핑용)
    private(set) var zones: [Zone] = []

    /// 이벤트 확정 훅 — provider 가 받아 delegate·앱으로 흘린다.
    var onEvent: ((ZoneEvent) -> Void)?
    /// 진단 로그 훅
    var onLog: ((LogLevel, String) -> Void)?
    /// 진단 코드 훅 — 화면 로그로 끝내지 않고 서버(E-코드)까지 올릴 것만 여기로 보낸다.
    var onReport: ((SdkErrorCode, String) -> Void)?

    /// 판정 파라미터 무력화 경고는 층당 1회만 — 존을 갈아끼울 때마다 반복하면 로그가 덮인다.
    private var warnedParamsIgnored = false

    private var nameToZone: [String: Zone] = [:]
    private var activeZoneId: String?
    private var dwellTask: Task<Void, Never>?
    /// 매핑 실패는 이름당 1회만 경고한다 — IN/OUT 이 반복되면 로그가 덮인다.
    private var warnedNames: Set<String> = []

    // MARK: - 존 주입

    /// 콘솔 존 교체 (층 전환·폴링). 판정 상태는 버린다 —
    /// 사라진 존의 IN 상태가 남으면 이탈 이벤트가 영영 안 나온다.
    func apply(zones: [Zone]) {
        self.zones = zones
        reset()
        warnedNames = []

        nameToZone = [:]
        for z in zones {
            // ihub 영역 이벤트에 ID 가 없다 → name 이 키. 중복이면 #2, #3… 로 유일화
            // (PrmZoneEngine 과 같은 규칙 — 콘솔에서 같은 이름을 두 번 쓴 경우)
            var key = z.name
            var n = 2
            while nameToZone[key] != nil { key = "\(z.name)#\(n)"; n += 1 }
            nameToZone[key] = z
        }
        warnIfJudgingParamsIgnored()
    }

    /// 콘솔에서 판정 파라미터를 손댔는데 그 값이 아무 데도 안 쓰이는 상황을 드러낸다.
    ///
    /// PRM 경로에서는 이 값들이 실제 판정에 들어갔다. ihub 경로에서는 엔진이 자기 서버의
    /// 지오펜스로 판정하므로 **콘솔에서 무엇을 넣든 판정이 변하지 않는다.** 조용히 두면
    /// "값을 바꿨는데 왜 그대로냐"를 현장에서 며칠씩 파게 된다 — 그래서 한 번 말해 준다.
    private func warnIfJudgingParamsIgnored() {
        guard !warnedParamsIgnored else { return }
        let tuned = zones.filter { $0.inDist > 0 || $0.inCount > 0 || $0.outPeriod > 0 }
        guard !tuned.isEmpty else { return }
        warnedParamsIgnored = true
        onLog?(.warn, SdkLocalized.format("ihub.paramsIgnored", tuned.count))
    }

    // MARK: - ihub 영역 이벤트

    /// ihub `onAreaEvent(floorId:areaName:inOut:)` 를 받아 ZoneEvent 로 옮긴다.
    /// - Parameters:
    ///   - inOut: ihub 가 주는 `"IN"` / `"OUT"` 문자열 (그 밖의 값은 무시)
    ///   - at: 발생 시각 (테스트용 시계 주입)
    func handleAreaEvent(inOut: String, areaName: String, at: Date = Date()) {
        guard let zone = nameToZone[areaName] else {
            // 이름이 유일한 연결고리라 여기가 끊기면 그 영역의 시책이 통째로 안 돈다.
            // 화면 로그로만 남기면 현장에서만 보이고 관리자는 영영 모른다 → E-코드로도 올린다.
            if warnedNames.insert(areaName).inserted {
                onLog?(.warn, SdkLocalized.format("ihub.areaUnmapped", areaName, zones.count))
                onReport?(.zoneMappingFailed, "area=\(areaName) consoleZones=\(zones.count)")
            }
            return
        }
        switch inOut {
        case "IN":
            activeZoneId = zone.id
            onEvent?(.enter(zone: zone, at: at))
            startDwell(zone: zone)
        case "OUT":
            if activeZoneId == zone.id { reset() }
            onEvent?(.exit(zone: zone, at: at))
        default:
            onLog?(.warn, SdkLocalized.format("ihub.areaUnknown", inOut, areaName))
        }
    }

    /// 판정 상태 초기화 (측위 시작·층 전환·정지). 존 목록은 유지한다.
    func reset() {
        dwellTask?.cancel()
        dwellTask = nil
        activeZoneId = nil
    }

    // MARK: - DWELL 파생

    /// 체류시간(dwell_seconds) 도달 시 1회 발화 (콘솔 "체류 트리거" 의미 그대로).
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
}
