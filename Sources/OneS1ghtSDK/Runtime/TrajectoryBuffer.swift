//
//  TrajectoryBuffer.swift
//  좌표 버퍼 — 인메모리 (프롬프트 결정사항 3: 디스크 영속은 v2)
//
//  · add로 축적 → flush 시 오래된 것부터 maxPerRequest(500)씩 잘라 전송 (사양서 §6.5 상한)
//  · 전송 성공(200)한 배치만 제거 — 실패하면 유지 → 다음 flush 때 재시도 (사양서 §9)
//  · flush "트리거"(100건/5분/종료/백그라운드)는 SessionCoordinator가 당긴다
//

import Foundation

@MainActor
final class TrajectoryBuffer {

    /// 배치 전송기 — true 반환 = 서버 200 (버퍼에서 제거해도 됨)
    typealias Sender = ([PositionPoint]) async -> Bool

    private(set) var points: [PositionPoint] = []
    private let maxPerRequest: Int
    private let send: Sender
    private var isFlushing = false          // 재진입 방지 (트리거 중복 시 이중 전송 차단)

    init(maxPerRequest: Int = 500, send: @escaping Sender) {
        self.maxPerRequest = maxPerRequest
        self.send = send
    }

    var count: Int { points.count }

    func add(_ p: PositionPoint) { points.append(p) }

    /// 쌓인 전부를 상한 단위로 전송. 중간 실패 시 남은 건 유지하고 중단.
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !points.isEmpty {
            let batch = Array(points.prefix(maxPerRequest))
            guard await send(batch) else { break }      // 실패 → 유지, 다음 기회에 재시도
            points.removeFirst(batch.count)             // 성공분만 제거 (그 사이 add된 건 보존)
        }
    }
}
