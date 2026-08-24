//
//  LiveConfigStream.swift
//  콘솔 변경 실시간 수신 (SSE).
//
//  · 측위 세션 구간에만 연결한다 — 존·도면이 실제로 쓰이는 구간과 일치하고,
//    동시 연결 수가 동시 체류 인원을 넘지 않는다.
//  · iOS 는 백그라운드에서 연결을 끊는다. 그래서 연결이 될 때마다 .resyncNeeded 를 올린다 —
//    "연결됐다"는 곧 "그 사이를 놓쳤을 수 있다"는 뜻이다.
//  · ⚠️ 받은 신호로 무엇을 할지는 **고객사가 정한다.** 이 클래스는 존을 다시 받지 않고,
//    신호를 접지도 않는다. 디바운스가 필요하면 고객사가 건다.
//  · 외부 의존성 0 (URLSession.bytes(for:), iOS 15+).
//

import Foundation

final class LiveConfigStream {

    /// 콘솔에서 무언가 바뀌었다 / 재동기화가 필요하다.
    var onChange: ((ConfigChange) -> Void)?
    /// 내부 활동 로그 — SessionCoordinator 의 onLog 로 이어진다.
    var onLog: ((String) -> Void)?

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    private var task: Task<Void, Never>?
    private var lastSeq: Int?

    private let minBackoff: TimeInterval = 1
    private let maxBackoff: TimeInterval = 30

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// 안전망 — `stop()` 을 거쳐 정상 종료되는 경로에서 task 정리를 한 번 더 보장한다.
    /// ⚠️ `start()` 의 재연결 루프는 `[weak self]` 로 캡처하지만 `guard let self` 로
    /// 언랩한 뒤로는 루프가 도는 내내 스스로를 강하게 쥔다 — 그래서 소유자가 `stop()`
    /// 없이 참조만 놓으면 이 인스턴스는 그 루프에 의해 계속 살아 있고, 이 경우
    /// `deinit` 도 불리지 않는다(참조가 완전히 사라져야 실행되는데, 그 참조를
    /// 이 루프 자신이 쥐고 있기 때문). 소유자는 여전히 `stop()` 을 반드시 불러야 한다.
    deinit { task?.cancel() }

    // MARK: - 수명주기

    func start(buildingId: String?, floorId: String?) {
        stop()
        lastSeq = nil
        task = Task { [weak self] in
            guard let self else { return }
            var backoff = self.minBackoff
            while !Task.isCancelled {
                let connected = await self.consume(buildingId: buildingId, floorId: floorId)
                if Task.isCancelled { return }
                if connected { backoff = self.minBackoff }
                let wait = Self.jitter(backoff)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                backoff = min(backoff * 2, self.maxBackoff)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - 수신

    /// 한 번 붙어서 끊길 때까지 읽는다. 반환값 = 실제로 붙었는가(백오프 초기화 판단용).
    private func consume(buildingId: String?, floorId: String?) async -> Bool {
        var comps = URLComponents(url: baseURL.appendingPathComponent("stream"),
                                  resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if let buildingId { items.append(URLQueryItem(name: "buildingId", value: buildingId)) }
        if let floorId { items.append(URLQueryItem(name: "floorId", value: floorId)) }
        comps?.queryItems = items.isEmpty ? nil : items
        guard let url = comps?.url else { return false }

        var req = URLRequest(url: url)
        // timeoutInterval 은 기본값(60초)을 그대로 쓴다. 이건 "요청 전체" 타임아웃이 아니라
        // "직전 데이터 수신 이후 무응답" 타임아웃(inactivity timeout)이라서 — 서버가 20초마다
        // `: ping` 을 보내 이 시계를 계속 되돌려 주므로, 살아있는 스트림은 절대 타임아웃되지
        // 않고 서버가 조용히 죽은 스트림은 60초 안에 감지돼 재연결된다.
        // ⚠️ 서버 ping 주기가 이 60초에 근접하거나 넘어가면 연결이 주기적으로
        // 타임아웃→재연결을 반복하게 된다 — 그 상수를 바꿀 땐 이 커플링을 먼저 볼 것.
        req.setValue(apiKey, forHTTPHeaderField: "X-SDK-Key")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                onLog?("live: 연결 거절 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return false
            }
            onLog?("live: 연결됨")
            lastSeq = nil                             // 새 연결 = 새 기준선
            onChange?(.resyncNeeded)                  // 붙었다 = 그 사이를 놓쳤을 수 있다

            var parser = SseFrameParser()
            for try await line in bytes.lines {
                if Task.isCancelled { return true }
                for frame in parser.feed(line + "\n") { accept(frame) }
            }
            return true
        } catch {
            onLog?("live: 끊김 \(error)")
            return false
        }
    }

    /// 프레임 1건 처리 — 갭 판정 후 고객사 통지.
    private func accept(_ frame: SseFrame) {
        guard let signal = LiveSignal.parse(frame) else { return }
        if let seq = signal.seq {
            if let last = lastSeq, seq != last + 1 {
                onLog?("live: 일련번호 갭 \(last) → \(seq), 재동기화 요청")
                onChange?(.resyncNeeded)
            }
            lastSeq = seq
        }
        if let change = signal.change { onChange?(change) }
    }

    /// 갭 판정만 떼어 검증하기 위한 진입점 (테스트 전용 — 네트워크를 타지 않는다).
    func acceptForTest(_ frame: SseFrame) { accept(frame) }

    /// ±20% 흔들어 재연결이 한꺼번에 몰리지 않게 한다.
    private static func jitter(_ s: TimeInterval) -> TimeInterval {
        s * Double.random(in: 0.8...1.2)
    }
}
