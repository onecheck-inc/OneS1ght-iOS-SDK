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

    /// 안전망 — `stop()` 을 거치는 정상 종료 경로에서 task 정리를 한 번 더 보장하는
    /// 이중 안전장치일 뿐이다. 재연결 루프(아래 `start()`) 는 이제 반복마다 `self` 를
    /// 새로 얻으므로, 참조가 끊기면 그 자체로 다음 반복에서 스스로 빠진다 — 이 `deinit`
    /// 이 참조 누수를 막아 주는 장치는 아니다.
    deinit { task?.cancel() }

    // MARK: - 수명주기

    func start(buildingId: String?, floorId: String?) {
        stop()
        lastSeq = nil
        // 루프 본문이 self 없이도 백오프 한계값을 읽을 수 있도록 미리 지역변수로 뗀다 —
        // 그래야 대기(sleep) 구간에서 self 를 붙잡고 있을 이유가 하나도 남지 않는다.
        let minBackoff = self.minBackoff
        let maxBackoff = self.maxBackoff
        task = Task { [weak self] in
            var backoff = minBackoff
            while !Task.isCancelled {
                var connected = false
                do {
                    // self 를 이 블록 안에서만 강하게 쥔다 — 블록이 끝나면(= sleep 에 들어가기
                    // 전에) 곧바로 풀린다. 그래서 재연결 대기 중에 소유자가 참조를 놓으면,
                    // 다음 반복의 guard 가 self 를 다시 얻지 못하고 루프가 빠진다.
                    // (연결이 실제로 살아있어 consume() 이 아직 안 끝난 동안은 그 구간만큼은
                    // self 가 강하게 쥐어진다 — 무한이 아니라 그 접속이 끝날 때까지로 한정된다.)
                    guard let self else { return }
                    connected = await self.consume(buildingId: buildingId, floorId: floorId)
                }
                if Task.isCancelled { return }
                if connected { backoff = minBackoff }
                let wait = Self.jitter(backoff)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                backoff = min(backoff * 2, maxBackoff)
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
            /* ⚠️ bytes.lines 를 쓰지 않는다.
               SSE 는 **빈 줄**로 프레임이 끝나는데 AsyncLineSequence 는 그 빈 줄을 돌려주지
               않는다. 그러면 파서 버퍼에 \n\n 이 영영 만들어지지 않아 프레임이 하나도
               완성되지 않는다 — 연결도 되고 하트비트도 받는데 이벤트만 조용히 사라진다.
               연결 직후의 .resyncNeeded 는 파서를 거치지 않고 나가므로 정상으로 보여
               증상이 더 헷갈렸다(2026-08-25 실기기).
               줄 끝(\n)을 만날 때마다 그 줄을 그대로 넘긴다 — 빈 줄이면 "\n" 하나가
               넘어가고, 직전 줄의 \n 과 합쳐져 경계가 된다. */
            var pending = Data()
            for try await byte in bytes {
                if Task.isCancelled { return true }
                pending.append(byte)
                guard byte == 0x0A else { continue }          // 줄이 끝날 때만 넘긴다
                if let line = String(data: pending, encoding: .utf8) {
                    for frame in parser.feed(line) { accept(frame) }
                }
                pending.removeAll(keepingCapacity: true)
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
