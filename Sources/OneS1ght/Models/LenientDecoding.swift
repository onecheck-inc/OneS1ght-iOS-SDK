//
//  LenientDecoding.swift
//  서버가 늘리거나 바꿀 수 있는 응답을 **요소 단위로** 관대하게 읽는 도우미.
//
//  ⚠️ 2026-08-21 에 서버가 remote_config 에 정수·불리언을 담자 `[String: String]` 디코드가 깨져
//     이미 배포된 앱의 initialize 가 전부 실패했다(앱 벽돌). 같은 종류의 엄격한 디코드가 존 이벤트·
//     좌표 전송·구역 응답에 남아 있었다(2026-10-02 감사 S17):
//       · id 를 숫자·null 로 주면 쿠폰(트리거)이 통째로 사라지고,
//       · 200 응답을 실패로 읽어 같은 좌표를 다시 보내고,
//       · 구역 하나가 틀리면 그 층 구역 전체가 빈다.
//     그래서 "그 항목만 버리고 나머지는 산다" 를 기본으로 한다.
//

import Foundation

/// 원소를 하나씩 읽어, 못 읽는 원소만 버리는 배열.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    /// 못 읽고 버린 원소 수 — 진단용.
    let dropped: Int

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        var dropped = 0
        while !c.isAtEnd {
            if (try? c.decodeNil()) == true {          // null 원소 — decodeNil 이 한 칸 소비한다
                dropped += 1
            } else if let e = try? c.decode(Element.self) {
                out.append(e)
            } else {
                // 실패한 원소를 건너뛰어야 다음으로 간다 — 아무 값으로나 한 칸 소비한다.
                _ = try? c.decode(Skip.self)
                dropped += 1
            }
        }
        elements = out
        self.dropped = dropped
    }

    /// 어떤 값이든 받아 넘기기만 한다 — init 이 던지지 않으므로 디코더가 반드시 한 칸 나아간다.
    private struct Skip: Decodable { init(from decoder: Decoder) {} }
}

/// 문자열로 오든 숫자로 오든 문자열로 받는 ID.
struct FlexibleID: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s; return }
        if let i = try? c.decode(Int64.self) { value = String(i); return }
        throw DecodingError.typeMismatch(String.self, .init(
            codingPath: decoder.codingPath,
            debugDescription: "id 가 문자열도 숫자도 아닙니다"))
    }
}

extension KeyedDecodingContainer {
    /// 문자열·숫자 어느 쪽이든 문자열로. 없거나 null 이거나 다른 타입이면 nil.
    func lenientID(_ key: Key) -> String? {
        (try? decodeIfPresent(FlexibleID.self, forKey: key))??.value
    }

    /// 배열을 원소 단위로. 키가 없거나 배열이 아니면 빈 배열.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent(LossyArray<T>.self, forKey: key)) ?? nil)?.elements ?? []
    }

    /// 타입이 틀리거나 없으면 nil — 선택 필드용.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
