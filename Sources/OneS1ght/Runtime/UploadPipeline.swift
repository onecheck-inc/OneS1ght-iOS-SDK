//
//  UploadPipeline.swift
//  좌표 수집 → 서버 전송. 다운샘플(position_rate_hz)·버퍼·전송 시점(300건 도달/60초 타이머)을 맡는다.
//
//  SessionCoordinator 에서 떼어 냈다(2026-10-02 감사 K7).
//
//  배치 정책 (사양서 §6.8 은 100건/5분 "권장" — 2026-08-20 300건/60초로 조정.
//  4Hz 에서는 300건(=75초)보다 60초 타이머가 먼저 걸려 실질 60초·240건 주기가 된다.
//  종전 100건/300초는 25초마다 100건 → 요청 수가 2.4배였다. 테스트에서 작게 주입.)
//

import Foundation

@MainActor
final class UploadPipeline {

    /// 지금 세션의 귀속 키 — 프로필과 방문. 없으면 보내지 않는다.
    struct Owner { let profileId: String; let visitorId: String }

    private let api: ApiClient
    private let reporter: SdkReporter
    private let owner: () -> Owner?
    private let flushThreshold: Int
    private let flushInterval: TimeInterval
    private(set) var buffer: TrajectoryBuffer!
    private var flushTimer: Timer?

    /// 서버 전송 주기(Hz) — verify 가 내려준 값. 범위 밖·미회신은 기본값(4Hz)으로 접힌 값이 들어온다.
    var positionRateHz = SdkDefaults.positionRateHz
    /// 다운샘플 기준 시각 — 판정 입력은 솎지 않는다(서버 전송분만).
    private var lastRecordedAt: Date?

    init(api: ApiClient, reporter: SdkReporter, flushThreshold: Int, flushInterval: TimeInterval,
         maxPerRequest: Int, owner: @escaping () -> Owner?) {
        self.api = api
        self.reporter = reporter
        self.flushThreshold = flushThreshold
        self.flushInterval = flushInterval
        self.owner = owner
        self.buffer = TrajectoryBuffer(maxPerRequest: maxPerRequest) { [weak self] batch in
            await self?.send(batch) ?? false
        }
    }

    var pendingCount: Int { buffer.count }

    /// 새 방문 — 다운샘플 기준을 지우고 60초 타이머를 건다.
    func beginSession() {
        lastRecordedAt = nil
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.buffer.flush() }
        }
    }

    func endSession() {
        flushTimer?.invalidate(); flushTimer = nil
    }

    /// 좌표 한 점. 다운샘플을 통과하면 쌓고, 임계에 **닿는 순간** 보낸다.
    func record(_ coordinates: Coordinates, floorId: String, at capturedAt: Date) {
        guard shouldRecord(at: capturedAt) else { return }
        let before = buffer.count
        buffer.add(PositionPoint(floor_id: floorId,
                                 coordinates: coordinates,
                                 captured_at: SessionCoordinator.iso(capturedAt)))
        // ⚠️ 임계를 **넘어서는 순간에만** 당긴다. 예전엔 `>=` 라, 오프라인에서 한 번 실패해 버퍼가
        //    임계 위에 머무르면 좌표(4Hz)마다 새 전송을 시도했고 실패마다 E5001(ERROR) 로그 전송까지
        //    붙어 기기당 초당 ~8요청이 났다(2026-10-02 감사 S5). 실패분은 60초 타이머가 다시 보낸다.
        if before < flushThreshold, buffer.count >= flushThreshold {
            Task { await buffer.flush() }
        }
    }

    /// 쌓인 좌표를 지금 보낸다.
    func flush() async { await buffer.flush() }
    /// 쌓인 좌표를 보내지 않고 버린다.
    func discard() { buffer.empty() }

    /// position_rate_hz 다운샘플 판정.
    /// 경계에 10% 여유를 둔다 — 4Hz 설정에 4Hz 입력이면 간격이 0.25초 언저리로 흔들려,
    /// 정확히 1/rate 로 자르면 절반이 버려진다(기본값에서 동작이 바뀌면 안 된다).
    private func shouldRecord(at t: Date) -> Bool {
        let minGap = (1.0 / Double(positionRateHz)) * 0.9
        if let last = lastRecordedAt, t.timeIntervalSince(last) < minGap { return false }
        lastRecordedAt = t
        return true
    }

    /// 좌표 벌크 전송 (buffer의 Sender) — true = 200
    private func send(_ batch: [PositionPoint]) async -> Bool {
        guard let owner = owner() else { return false }
        let req = ReqPositionBulk(profile_id: owner.profileId,
                                  visitor_id: owner.visitorId,
                                  platform_name: SdkPlatform.name,
                                  points: batch)
        do {
            let res = try await api.sendPositionLogs(req)
            reporter.log(.info, SdkLocalized.format("coord.logsSent", batch.count, res.accepted_count ?? batch.count))
            return true
        } catch {
            reporter.reportApi(error, "positions=\(batch.count)",
                               message: SdkLocalized.format("coord.logsFail", batch.count))
            return false
        }
    }
}
