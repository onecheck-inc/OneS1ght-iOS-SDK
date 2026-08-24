//
//  ConfigChange.swift
//  콘솔에서 바뀐 것 — 고객사에게 알리는 형태.
//
//  ⚠️ 이벤트는 얇다. "무엇이 바뀌었다"만 오고 값은 오지 않는다(rate_hz 처럼 작은 값은 예외).
//     무엇을 다시 받을지는 고객사가 정한다 — SDK 는 대신 정하지 않는다.
//

import Foundation

/// 콘솔 변경 알림 — `FloorSession.onConfigChanged` 로 전달된다.
public enum ConfigChange: Equatable {
    /// 구역이 생기거나 바뀌거나 사라졌다.
    case zonesChanged(floorId: String?)
    /// 층 도면이 바뀌었다.
    case planChanged(floorId: String?)
    /// 시책 상태가 바뀌었다(실행·활성화·연결·중지).
    case rulesChanged(zoneId: String?)
    /// 원격 설정이 바뀌었다. 값이 직접 실려 온다.
    case sdkConfigChanged(rateHz: Int?, logLevel: String?)
    /// 연결이 (재)수립됐거나 이벤트를 놓쳤다 — 그 사이에 무엇이든 바뀌었을 수 있다.
    /// 지금 쓰고 있는 것을 통째로 다시 받아야 한다.
    case resyncNeeded
}

/// 프레임 1건의 해석 결과 — 일련번호와(있으면) 변경 내용.
struct LiveSignal {
    let seq: Int?
    let change: ConfigChange?

    /**
     프레임을 신호로 바꾼다. JSON 이 깨졌으면 nil(그 한 건만 버린다).

     ⚠️ **모르는 `event` 타입도 nil 이 아니라 `change == nil` 로 돌려준다.** 서버가 새 타입을
     늘렸을 때 seq 추적이 끊기면 다음 이벤트에서 갭 오탐이 나 불필요한 재동기화가 돈다.
     */
    static func parse(_ frame: SseFrame) -> LiveSignal? {
        guard let raw = frame.data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        let seq = obj["seq"] as? Int
        let floorId = obj["floor_id"] as? String

        switch frame.event {
        case "zones.changed":
            return LiveSignal(seq: seq, change: .zonesChanged(floorId: floorId))
        case "plan.changed":
            return LiveSignal(seq: seq, change: .planChanged(floorId: floorId))
        case "rules.changed":
            let zoneId = obj["zone_id"].map { "\($0)" }
            return LiveSignal(seq: seq, change: .rulesChanged(zoneId: zoneId))
        case "sdk.config.changed":
            return LiveSignal(seq: seq, change: .sdkConfigChanged(rateHz: obj["rate_hz"] as? Int,
                                                                  logLevel: obj["log_level"] as? String))
        default:
            return LiveSignal(seq: seq, change: nil)     // hello 포함 — 기준선만 갱신
        }
    }
}
