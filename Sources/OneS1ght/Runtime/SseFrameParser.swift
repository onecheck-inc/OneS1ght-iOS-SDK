//
//  SseFrameParser.swift
//  SSE 프레임 파서 — 바이트 스트림에서 event/data 프레임을 꺼낸다.
//
//  네트워킹과 분리한 순수 상태기계다. 청크는 프레임 경계와 무관하게 잘려 오므로
//  버퍼에 이어 붙였다가 빈 줄(\n\n)이 나올 때만 프레임 하나를 완성한다.
//

import Foundation

/// 완성된 프레임 1건.
struct SseFrame: Equatable {
    /// `event:` 가 없으면 SSE 표준 기본값 `message`.
    let event: String
    /// `data:` 줄들을 개행으로 이어 붙인 것.
    let data: String
}

struct SseFrameParser {

    private var buffer = ""

    /// 청크를 먹이고 이번에 완성된 프레임들을 돌려준다. 완성된 게 없으면 빈 배열.
    mutating func feed(_ chunk: String) -> [SseFrame] {
        buffer += chunk
        var out: [SseFrame] = []
        while let range = buffer.range(of: "\n\n") {
            let raw = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            if let frame = Self.parse(raw) { out.append(frame) }
        }
        return out
    }

    /// 프레임 한 덩어리를 해석한다. `:` 로 시작하는 줄은 주석(하트비트)이라 버린다.
    /// data 가 하나도 없으면 프레임으로 치지 않는다.
    private static func parse(_ raw: String) -> SseFrame? {
        var event = "message"
        var data: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            }
        }
        guard !data.isEmpty else { return nil }
        return SseFrame(event: event, data: data.joined(separator: "\n"))
    }
}
