//
//  SdkLogBuffer.swift
//  SDK 로그 버퍼 — 관리자가 콘솔 로그 분석기에서 볼 줄을 모아 배치 전송한다.
//
//  · 좌표 버퍼(TrajectoryBuffer)와 같은 구조이되 임계가 작다(50건/60초).
//    로그는 양이 적고 진단이 목적이라 빨리 도달해야 한다.
//  · ERROR 는 즉시 flush — 앱이 죽기 전에 남겨야 원인을 안다.
//  · **전송 실패가 앱 동작을 막지 않는다.** 로그는 부가 기능이고, 실패분은 버린다
//    (좌표와 달리 재시도로 붙들면 진짜 데이터가 밀린다).
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

    private(set) var entries: [SdkLogEntry] = []
    private var isFlushing = false          // 재진입 방지

    /// 폭주 방어 — 같은 코드가 쏟아져도 버퍼가 무한히 자라지 않게 상한을 둔다.
    /// 넘치면 **오래된 것부터** 버린다(최근 상황이 진단에 더 쓸모 있다).
    private let hardLimit: Int

    init(threshold: Int = 50, maxPerRequest: Int = 500, hardLimit: Int = 2000,
         send: @escaping Sender) {
        self.threshold = threshold
        self.maxPerRequest = maxPerRequest
        self.hardLimit = hardLimit
        self.send = send
    }

    var count: Int { entries.count }

    /// 로그 적재. ERROR 면 즉시 전송을 시도한다.
    func add(_ entry: SdkLogEntry) {
        entries.append(entry)
        if entries.count > hardLimit {
            entries.removeFirst(entries.count - hardLimit)
        }
        if entry.level == SdkLogLevel.error.rawValue || entries.count >= threshold {
            Task { await flush() }
        }
    }

    /// 쌓인 전부를 상한 단위로 전송. 실패한 배치는 **버린다**(§파일 헤더).
    func flush() async {
        guard !isFlushing, !entries.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !entries.isEmpty {
            let batch = Array(entries.prefix(maxPerRequest))
            entries.removeFirst(batch.count)       // 성공·실패와 무관하게 먼저 뗀다
            if await send(batch) == false { break } // 실패하면 나머지도 이번엔 포기
        }
    }

    /// 전송 없이 비운다 (reset·키 교체 등).
    func empty() { entries.removeAll() }
}
