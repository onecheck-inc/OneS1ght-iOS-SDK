//
//  SdkLogBuffer.swift
//  SDK 로그 버퍼 — 관리자가 콘솔 로그 분석기에서 볼 줄을 모아 배치 전송한다.
//
//  · 좌표 버퍼(TrajectoryBuffer)와 같은 구조이되 임계가 작다(50건). 시간 타이머는 없다 —
//    50건·ERROR·세션 종료·프로필 연결 때 나간다.
//  · ERROR 는 즉시 flush — 앱이 죽기 전에 남겨야 원인을 안다.
//  · **전송 실패가 앱 동작을 막지 않는다.** 로그는 부가 기능이고, 실패분은 버린다
//    (좌표와 달리 재시도로 붙들면 진짜 데이터가 밀린다).
//  · **보낼 곳이 아직 없으면(프로필 연결 전) 붙들고 있는다.** 예전엔 그때도 버퍼에서 떼어 낸 뒤
//    버려서, 문서 순서(initialize → identify)대로면 초기화 중 E1007 이 영영 콘솔에 안 갔다
//    (2026-10-02 감사 S13). 프로필이 생기면 코디네이터가 flush 를 당긴다.
//  · **실패하면 잠시 쉰다.** 오프라인에서 ERROR 가 날 때마다 즉시 전송을 다시 시도해 좌표 실패
//    로그와 맞물려 초당 요청이 폭주했다(S5). 실패 뒤에는 대기 시간이 지날 때까지 자동 flush 를
//    건너뛴다(세션 종료 같은 명시적 flush 는 그대로 시도한다).
//

import Foundation

@MainActor
final class SdkLogBuffer {

    /// 배치 전송기 — true = 서버 200
    typealias Sender = ([SdkLogEntry]) async -> Bool

    /// 요청당 상한 (서버가 500 초과 시 422)
    private let maxPerRequest: Int
    /// 이 건수에 닿으면 flush
    private let threshold: Int
    private let send: Sender
    /// 지금 보낼 수 있는가 — 프로필이 없으면 귀속할 곳이 없어 보내지 않고 붙든다.
    private let canSend: () -> Bool
    private let now: () -> Date

    private(set) var entries: [SdkLogEntry] = []
    private var isFlushing = false          // 재진입 방지

    /// 폭주 방어 — 같은 코드가 쏟아져도 버퍼가 무한히 자라지 않게 상한을 둔다.
    /// 넘치면 **오래된 것부터** 버린다(최근 상황이 진단에 더 쓸모 있다).
    private let hardLimit: Int

    /// 실패 뒤 자동 flush 를 쉬는 시간 — 실패할 때마다 두 배(최대 maxBackoff), 성공하면 처음으로.
    private let minBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private var backoff: TimeInterval
    private(set) var retryNotBefore: Date?

    init(threshold: Int = 50, maxPerRequest: Int = SdkLimits.maxPerRequest, hardLimit: Int = 2000,
         minBackoff: TimeInterval = 5, maxBackoff: TimeInterval = 60,
         now: @escaping () -> Date = Date.init,
         canSend: @escaping () -> Bool = { true },
         send: @escaping Sender) {
        self.threshold = threshold
        self.maxPerRequest = maxPerRequest
        self.hardLimit = hardLimit
        self.minBackoff = minBackoff
        self.maxBackoff = maxBackoff
        self.backoff = minBackoff
        self.now = now
        self.canSend = canSend
        self.send = send
    }

    var count: Int { entries.count }

    /// 로그 적재. ERROR 거나 임계에 닿으면 전송을 시도한다(쉬는 중이면 건너뛴다).
    func add(_ entry: SdkLogEntry) {
        entries.append(entry)
        if entries.count > hardLimit {
            entries.removeFirst(entries.count - hardLimit)
        }
        if entry.level == SdkLogLevel.error.rawValue || entries.count >= threshold {
            Task { await flushIfDue() }
        }
    }

    /// 자동 trigger 용 — 실패 뒤 쉬는 중이면 아무것도 안 한다.
    func flushIfDue() async {
        if let t = retryNotBefore, now() < t { return }
        await flush()
    }

    /// 쌓인 전부를 상한 단위로 전송. 실패한 배치는 **버린다**(§파일 헤더).
    /// 보낼 곳이 없으면(canSend == false) 건드리지 않고 그대로 붙든다.
    func flush() async {
        guard !isFlushing, !entries.isEmpty, canSend() else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !entries.isEmpty {
            let batch = Array(entries.prefix(maxPerRequest))
            entries.removeFirst(batch.count)       // 성공·실패와 무관하게 먼저 뗀다
            if await send(batch) == false {        // 실패하면 나머지도 이번엔 포기하고 쉰다
                retryNotBefore = now().addingTimeInterval(backoff)
                backoff = min(backoff * 2, maxBackoff)
                return
            }
        }
        retryNotBefore = nil
        backoff = minBackoff
    }

    /// 전송 없이 비운다 (reset·키 교체 등).
    func empty() { entries.removeAll() }
}
