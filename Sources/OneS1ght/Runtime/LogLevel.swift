//
//  LogLevel.swift
//  로그 한 줄의 등급.
//
//  예전에는 등급이라는 것이 없었고, 앱이 **글자 맨 앞의 이모지를 보고 짐작**했다
//  (⚠️ 면 오류, 🎯 면 존 판정…). 문구를 다듬다 이모지 하나가 빠지면 그 줄은 아무 경고
//  없이 다른 등급으로 내려앉았고, 실제로 "구역이 없다"는 정상 상태가 빨간 오류로 뜨고
//  있었다. 등급은 생김새가 아니라 값이어야 한다 — 그래서 이 타입이 있다.
//

import Foundation

/// 로그 한 줄의 등급. 낮은 것부터 `log < info < warn < error`.
public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    /// 흐름 기록 — 무슨 일이 일어났는지 남기는 것. 평상시엔 안 봐도 된다.
    case log
    /// 알아두면 좋은 것 — 정상이지만 눈에 띄면 도움이 되는 사실.
    case info
    /// 확인이 필요한 것 — 고장은 아니지만 이대로면 기대한 대로 안 돌아간다.
    case warn
    /// 고장 — 손대지 않으면 그 기능이 동작하지 않는다.
    case error

    /// "warn 이상만 남기기" 같은 거르기를 쓰기 위한 순서.
    public static func < (a: LogLevel, b: LogLevel) -> Bool {
        order(a) < order(b)
    }

    private static func order(_ l: LogLevel) -> Int {
        switch l {
        case .log: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }
}
