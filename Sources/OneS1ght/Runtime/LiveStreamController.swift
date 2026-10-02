//
//  LiveStreamController.swift
//  실시간 수신(SSE) 연결의 수명 — 언제 붙이고, 어떤 층 필터로, 언제 다시 붙이는가.
//
//  SessionCoordinator 에서 떼어 냈다(2026-10-02 감사 K7). 연결 자체(재연결·백오프·파싱)는
//  LiveConfigStream 이 하고, 여기는 "붙어 있어야 하는가 · 필터가 바뀌었는가" 만 본다.
//

import Foundation

@MainActor
final class LiveStreamController {

    /// 콘솔 변경 — 메인에서 불린다.
    var onChange: ((ConfigChange) -> Void)?
    /// 스트림 활동 로그 — 메인에서 불린다.
    var onLog: ((LogLevel, String) -> Void)?

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    private var live: LiveConfigStream?
    /// 지금 붙어 있는 스트림이 어떤 층으로 구독했는지 — 재연결 여부 판단용.
    private var liveFilter: FloorState?

    init(baseURL: URL, apiKey: String, session: URLSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    var isAttached: Bool { live != nil }

    /// 스트림을 붙여 둘 조건 — **층이 정해졌거나 측위가 도는 동안**.
    ///
    /// 처음에는 측위 세션 구간에만 붙였다. 동시 연결 수를 동시 체류 인원으로 묶어 서버 부하를
    /// 통제하려는 의도였는데, 그러면 **층을 골라 도면을 보고 있는 동안에는 콘솔 변경이 오지
    /// 않는다.** 실기기에서 바로 드러났다 — 초기화만 된 상태로는 아무리 기다려도 반영이 없고
    /// 수동 새로고침만 동작했다. 층을 띄워 둔 기기는 이미 "쓰고 있는" 기기라, 연결 수는
    /// 여전히 유계다. (0.1.24 까지 이름에 ForTest 가 붙어 있었지만 운영 경로였다 — 감사 K10.)
    static func streamWanted(floorSet: Bool, running: Bool) -> Bool {
        floorSet || running
    }

    /// 스트림이 다시 구독해야 할 만큼 건물·층이 바뀌었는지. buildingId·floorId 만 본다: 같은 층이면
    /// zones 등 나머지 필드가 바뀌어도 구독 자체는 바뀔 이유가 없다(그건 refreshZones() 의 몫).
    static func filterChanged(from previous: FloorState?, to next: FloorState?) -> Bool {
        previous?.buildingId != next?.buildingId || previous?.floorId != next?.floorId
    }

    /// 필요하면 붙이고, 필터가 그대로면 아무것도 하지 않는다.
    /// 멱등이라 세션 시작·층 지정·포그라운드 복귀가 겹쳐 불려도 연결이 요동치지 않는다.
    /// ⚠️ 필터가 바뀌면 기존 연결을 먼저 끊는다 — 안 그러면 층 전환·포그라운드 복귀마다 이전 연결이
    /// 옛 필터를 문 채 살아남아 스트림이 중복으로 쌓인다.
    func ensure(wanted: Bool, floor: FloorState?) {
        guard wanted else { detach(); return }
        if live != nil, !Self.filterChanged(from: liveFilter, to: floor) { return }
        live?.stop()
        let s = LiveConfigStream(baseURL: baseURL, apiKey: apiKey, session: session)
        // ⚠️ 스트림은 메인 밖에서 이 클로저들을 부른다 — 메인으로 넘긴 뒤 앱 훅(onDebugLog·onConfigChanged)에
        //    닿게 한다. 예전엔 로그를 그대로 불러 고객 앱의 onDebugLog 가 백그라운드 스레드에서 돌았다
        //    (Swift 6 의 @MainActor 클로저면 격리 검사로 크래시, Swift 5 면 데이터 경쟁 — S14).
        s.onLog = { [weak self] level, line in
            Task { @MainActor [weak self] in self?.onLog?(level, line) }
        }
        s.onChange = { [weak self] change in
            Task { @MainActor [weak self] in self?.onChange?(change) }
        }
        s.start(buildingId: floor?.buildingId, floorId: floor?.floorId)
        live = s
        liveFilter = floor
    }

    /// 백그라운드 — 연결만 끊는다. 복귀 때 forgetConnection() 뒤 ensure 가 새로 붙인다.
    func suspend() { live?.stop() }

    /// 배경에서 끊긴 연결을 잊는다 — 다음 ensure 가 같은 필터여도 새로 붙인다.
    func forgetConnection() { live = nil }

    /// 완전히 끊는다(필터도 잊는다).
    func detach() {
        live?.stop()
        live = nil
        liveFilter = nil
    }
}
