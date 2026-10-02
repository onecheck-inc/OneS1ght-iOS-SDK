//
//  TrajectoryBuffer.swift
//  좌표 버퍼 — 인메모리 (프롬프트 결정사항 3: 디스크 영속은 v2)
//
//  · add로 축적 → flush 시 오래된 것부터 maxPerRequest(500)씩 잘라 전송 (사양서 §6.5 상한)
//  · 전송 성공(200)한 배치만 제거 — 실패하면 유지 → 다음 flush 때 재시도 (사양서 §9)
//  · flush "트리거"(300건 도달 순간/60초/종료/백그라운드)는 SessionCoordinator가 당긴다
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
    /// empty() 가 불릴 때마다 오른다 — 전송 도중에 비워졌는지 알아보는 표식.
    private var generation = 0

    init(maxPerRequest: Int = SdkLimits.maxPerRequest, send: @escaping Sender) {
        self.maxPerRequest = maxPerRequest
        self.send = send
    }

    var count: Int { points.count }

    func add(_ p: PositionPoint) { points.append(p) }

    /// 쌓인 좌표를 전송 없이 버린다. flush 진행 중이어도 안전하다.
    ///
    /// ⚠️ 예전 주석은 "전송 성공분 제거(removeFirst)는 빈 배열에선 no-op" 이라고 했지만 틀렸다 —
    ///    `removeFirst(k)` 는 원소가 k 개보다 적으면 **크래시**한다. 공개 API `empty()` 를 전송 중에
    ///    부르면 앱이 죽었다(2026-10-02 감사, 단독 실행으로 재현). 이제 세대 번호로 "그 사이 비워졌다"
    ///    를 알아채고, 비워졌으면 아무것도 지우지 않는다(보낸 배치는 이미 버려진 것이다).
    func empty() {
        points.removeAll()
        generation += 1
    }

    /// 쌓인 전부를 상한 단위로 전송. 중간 실패 시 남은 건 유지하고 중단.
    /// - Returns: 남김없이 보냈는가(실패로 멈췄으면 false).
    @discardableResult
    func flush() async -> Bool {
        guard !isFlushing else { return true }
        isFlushing = true
        defer { isFlushing = false }

        while !points.isEmpty {
            let gen = generation
            let batch = Array(points.prefix(maxPerRequest))
            guard await send(batch) else { return false }   // 실패 → 유지, 다음 기회에 재시도
            guard gen == generation else { continue }        // 전송 중 empty() — 지울 것이 없다
            points.removeFirst(min(batch.count, points.count))   // 성공분만 제거 (그 사이 add된 건 보존)
        }
        return true
    }
}
