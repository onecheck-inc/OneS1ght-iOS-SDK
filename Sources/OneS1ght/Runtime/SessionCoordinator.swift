//
//  SessionCoordinator.swift
//  라이프사이클 상태기계 (사양서 §5) — SDK의 두뇌
//
//  prepare: verify(키검증) → /config(측위 키 등 — 실패해도 초기화는 성공, begin 에서 재시도)
//  start:   provider 가동 (identify 가 앞에 있어야 한다 — 인증 게이팅)
//    ├ didUpdate(좌표)       → 다운샘플 후 버퍼 적재 → 300건 도달/60초/종료/백그라운드에 벌크 전송
//    ├ didDetectZone         → events/zone 즉시 전송 (+network 1회 재시도) → triggers 호스트 전달
//    ├ didEmit·didDetectFloor → FloorSession 콜백으로 그대로
//    └ didStopUnexpectedly   → 다시 켜 보거나(3·10·30초) 세션을 닫는다
//
//  · 백그라운드: UWB 포그라운드 전용(결정사항 6) → 엔진 정지 + flush, 복귀 시 재개(일시정지는 유지)
//  · 실시간 수신(SSE): 층이 정해졌거나 측위가 도는 동안만 붙어 있다
//
//  여기는 **순서를 정하는 자리**다. 일은 부품이 한다(2026-10-02 감사 K7 — 한 타입에 책임 13개였다):
//    SdkReporter          화면 로그 + 서버 로그(코드)
//    UploadPipeline       다운샘플 · 좌표 버퍼 · 300건/60초 전송
//    LiveStreamController 실시간 연결의 수명·층 필터
//    EngineSupervisor     엔진이 스스로 꺼졌을 때 다시 켜기/포기
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 서버 에러(ApiError) 밖의 SDK 수준 실패
public enum SdkError: Error, Equatable {
    case notInitialized        // initialize() 안 하고 begin() 호출
    case notIdentified         // identify(profileId:) 없이 begin() 호출
    case positioningDisabled   // verify는 통과했으나 positioning_enabled=false
    case deviceNotSupported    // UWB 칩 없음 (측위 불가 기기)
    case osVersionTooLow       // iOS 27 미만
}

@MainActor
final class SessionCoordinator {

    // 의존성 (전부 주입 — 테스트는 스텁 세션·가짜 프로바이더)
    private let api: ApiClient
    private let identity: IdentityStore
    /// nil 로 시작해 resolveKeysFromConsole() 이 콘솔 키로 채운다. 콘솔이 키를 못 주면
    /// 계속 nil 이다: buildings()/floors()/zones() 는 빈 배열로, floor()/locators()/
    /// setFloorMap() 은 notInitialized 로 떨어진다(isInitialized 는 그래도 true — I1 참고).
    private var spaceClient: SpaceServiceClient?
    private var provider: PositioningProvider?   // start(provider:)에서 장착
    /// 지금 물려 있는 프로바이더 — FloorSession 의 pause/resume 이 읽는다.
    /// 코어는 일시정지를 알 필요가 없다(좌표가 안 올라오면 그만이다). 그래서 상태를
    /// 여기 복제하지 않고 프로바이더에게 그대로 묻는다 — 두 벌이 되면 어긋난다.
    var activeProvider: PositioningProvider? { provider }
    /// SpaceServiceClient 를 새로 만들 때 물려줄 세션 — 테스트는 스텁을 주입한다.
    /// 이게 없으면 콘솔 키로 만든 클라이언트가 항상 `.shared` 로 떨어져, 그 뒤의 첫
    /// 조회가 스텁을 우회하고 실제 서비스로 나간다(I3).
    private let session: URLSession

    /// 측위 엔진에 물릴 라이선스 — 콘솔이 유일한 출처다.
    private(set) var positioningLicense: String?
    /// 콘솔이 내려준 나머지 — 호스트 앱이 지도·도면에 쓴다.
    private(set) var googleMapKey: String?
    private(set) var spaceServiceKey: String?
    private(set) var spaceServiceBaseUrl: String?

    /// 가장 최근 `/config` 호출이 실패했는가(네트워크·서버 — 응답은 왔지만 값이 없는 것과
    /// 다르다) — FloorSession.begin() 의 순단 회복이 재시도할지 판단하는 자리(I1).
    /// 성공하면(geo_sdk_key 가 null 이어도) false 로 돌아온다: 그건 폴백할 게 없는 정상
    /// 상태이지 재시도로 해결될 문제가 아니다 — 같은 응답을 계속 다시 물어봐야 소용없다.
    private(set) var keyResolutionFailed = false

    // 부품 — 일은 이쪽이 하고 코디네이터는 순서만 정한다(파일 헤더).
    private let reporter: SdkReporter
    private var uploads: UploadPipeline!        // 배치 정책(300건/60초)은 UploadPipeline 헤더
    private let liveStream: LiveStreamController
    private let supervisor: EngineSupervisor

    /// 좌표 버퍼 — 테스트가 쌓인 수를 본다.
    var buffer: TrajectoryBuffer { uploads.buffer }

    // 상태
    private(set) var isPrepared = false           // initialize(=prepare) 성공 여부 = "세션 가능"
    private(set) var isRunning = false
    private(set) var visitorId = ""
    /// 앱이 넘긴 프로필 ID — 좌표·존 이벤트의 귀속 키
    private(set) var profileId: String?

    /// 서버가 verify 로 내려준 좌표 전송 주기(Hz)
    var positionRateHz: Int { uploads.positionRateHz }
    private(set) var floorState: FloorState?    // setFloorMap 결과 — start 시 provider 에 주입
    private(set) var currentFloor: Floor?        // setFloorMap 이 받은 Floor (floorSession 노출용)
    /// 수신 진단 1회 확인 — 측위 시작 후 이 시간 뒤에 본다.
    /// 7초는 데모 앱이 현장에서 쓰던 값이다(5초 자동진단 직후).
    private var receptionCheckTask: Task<Void, Never>?
    private let receptionCheckDelay: TimeInterval
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// 존 이벤트 응답의 개인화 액션 → 호스트 전달 (zoneId, triggers)
    var onTriggers: ((String, [Trigger]) -> Void)?

    /// 실시간 좌표 → 호스트 전달 (지도에 내 위치 찍기용 — 도면 로컬 미터)
    var onPosition: ((Coordinates) -> Void)?

    /// 엔진이 잡은 층(nil = 잃음) → FloorSession.onFloorDetected
    var onFloorDetected: ((String?) -> Void)?
    /// 구역 진입·이탈·체류 → FloorSession.onZoneEnter/Exit/Dwell
    var onZoneEvent: ((ZoneEvent) -> Void)?
    /// 측위 세션이 닫혔다(end() 또는 엔진 포기) → FloorSession.onStopped
    var onSessionClosed: ((FloorSession.StopReason) -> Void)?

    /// SDK 내부 활동 로그 (디버그) — verify·flush·zone 전송의 성공/실패를 호스트에 노출
    var onLog: ((LogLevel, String) -> Void)? {
        get { reporter.onLog }
        set { reporter.onLog = newValue }
    }
    private func log(_ msg: String) { reporter.log(msg) }
    private func log(_ level: LogLevel, _ msg: String) { reporter.log(level, msg) }

    /// 콘솔 변경 → 고객사 전달. SDK 는 이 신호로 아무것도 하지 않는다 —
    /// 무엇을 다시 받을지는 앱이 정한다.
    var onConfigChange: ((ConfigChange) -> Void)?

    // MARK: - 서버 로그 (콘솔 로그 분석기) — SdkReporter 로 넘긴다

    func report(_ code: SdkErrorCode, _ context: String = "", message: String? = nil) {
        reporter.report(code, context, message: message)
    }
    func report(_ code: SdkInfoCode, _ context: String = "", message: String? = nil) {
        reporter.report(code, context, message: message)
    }

    init(api: ApiClient,
         identity: IdentityStore,
         spaceClient: SpaceServiceClient? = nil,
         session: URLSession = .shared,
         flushThreshold: Int = 300,
         flushInterval: TimeInterval = 60,
         maxPerRequest: Int = SdkLimits.maxPerRequest,
         receptionCheckDelay: TimeInterval = 7,
         engineRestartDelays: [TimeInterval] = [3, 10, 30]) {
        self.receptionCheckDelay = receptionCheckDelay
        self.api = api
        self.identity = identity
        self.spaceClient = spaceClient
        self.session = session
        let reporter = SdkReporter(api: api)
        self.reporter = reporter
        self.liveStream = LiveStreamController(baseURL: api.baseURL, apiKey: api.apiKey, session: session)
        self.supervisor = EngineSupervisor(delays: engineRestartDelays, reporter: reporter)
        self.uploads = UploadPipeline(api: api, reporter: reporter,
                                      flushThreshold: flushThreshold, flushInterval: flushInterval,
                                      maxPerRequest: maxPerRequest) { [weak self] in
            guard let self, let profileId = self.profileId else { return nil }
            return .init(profileId: profileId, visitorId: self.visitorId)
        }
        liveStream.onLog = { [weak self] level, line in self?.log(level, line) }
        liveStream.onChange = { [weak self] change in self?.deliverConfigChange(change) }
    }

    // MARK: - 라이프사이클 (도식 1~5)

    /// 초기화(앱 시작 시 1회) — 키 검증 + 테넌트 SDK 설정 수신. 이게 전부다.
    /// 통과 = "세션 가능" 확정. 실패 사유는 throw (invalidKey/positioningDisabled/network).
    ///
    /// 건물·층은 여기서 건드리지 않는다 — 공간 선택은 buildings()/setFloorMap() 이라는
    /// 별도 메서드의 책임이고, 어느 층을 쓸지는 호스트 앱만 안다. 자동 선택을 두면
    /// 앱이 고르는 중에 SDK 가 다른 층으로 덮어쓰는 경합이 생긴다(08-11 실기기 확인).
    func prepare() async throws {
        guard !isPrepared else { return }                            // 멱등

        // 키 검증 — verify 성공 = 키 유효 + 백엔드 도달 가능 두 가지를 한 번에 확인한 것.
        let verified = try await api.verify(makeVerifyRequest())

        // 관련 키(특히 Google Maps 키)는 측위와 무관하다 — positioning_enabled 가드보다
        // 먼저 받아 둔다. 뒤에 두면 측위가 꺼진 테넌트는 지도 키조차 못 받는다(§3.2 "부분
        // 실패해도 200", 2026-09-09 판단 — I5).
        await resolveKeysFromConsole()

        guard verified.valid, verified.positioning_enabled else {
            throw SdkError.positioningDisabled
        }
        // 테넌트 설정 반영 — 범위 밖·미회신은 기본값(4Hz)으로 접는다
        let hz = verified.position_rate_hz ?? SdkDefaults.positionRateHz
        uploads.positionRateHz = min(max(hz, SdkDefaults.minRateHz), SdkDefaults.maxRateHz)
        report(.initialized, "tenant=\(verified.tenant_code ?? "?")",
               message: SdkLocalized.format("coord.verifyPass", verified.tenant_code ?? "?"))
        if positionRateHz != SdkDefaults.positionRateHz {
            report(.rateApplied, "rate=\(positionRateHz)",
                   message: SdkLocalized.format("coord.rateApplied", positionRateHz))
        }
        isPrepared = true
    }

    /// FloorSession.begin() 의 순단 회복이 부른다 — `/config` 가 실패했던 경우에만 재시도.
    /// isPrepared 는 건드리지 않는다(멱등 유지, I1) — 이 실패는 "세션이 안 됨"이 아니라
    /// "관련 키를 못 받음"이라 성격이 다르다. prepare() 를 다시 부르면 verify 를 또 태워
    /// 서버 부하만 늘고, isPrepared 멱등 가드에 걸려 애초에 아무것도 안 한다.
    func retryKeyResolutionIfNeeded() async {
        guard isPrepared, keyResolutionFailed else { return }
        await resolveKeysFromConsole()
    }

    /// 관련 키를 콘솔에서 받아 정본으로 삼는다.
    ///
    /// **초기화를 막지 않는다.** 서버가 잠깐 흔들린다고 앱이 못 뜨면 안 되므로, 실패해도
    /// prepare() 는 성공으로 끝내고 begin() 이 다시 시도한다.
    ///
    /// 고객은 OneS1ght SDK 키 하나만 넣는다 — 측위 공급자의 키는 통합관리자가 콘솔에
    /// 설정해 두고, 여기서 받아 쓴다. 앱이 그 키를 넘길 방법도, 알 필요도 없다.
    ///
    /// ⚠️ **못 받으면 그 사실을 크게 남긴다.** 폴백이 없으므로 못 받는 것은 곧 이번 세션
    /// 내내 공간 조회와 측위가 비활성이라는 뜻이다. 그런데 증상은 조용하다 —
    /// buildings()/floors()/zones() 는 빈 배열로 떨어져 "이 테넌트에 건물이 없다"와
    /// 구분이 안 되고, floor()/locators()/setFloorMap() 은 notInitialized 를 던지는데
    /// isInitialized 는 true 다. 그래서 E1007 로 남기고, begin() 이 다시 시도할 수 있게
    /// keyResolutionFailed 를 세워 둔다.
    private func resolveKeysFromConsole() async {
        let cfg: ResSdkConfig
        do {
            cfg = try await api.config()
            keyResolutionFailed = false
        } catch {
            keyResolutionFailed = true
            reportKeyUnavailable(reason: "config_failed")
            return
        }

        googleMapKey = cfg.google_map_key
        spaceServiceKey = cfg.geo_partner_key
        spaceServiceBaseUrl = cfg.geo_base_url

        guard let key = cfg.geo_sdk_key, !key.isEmpty else {
            // 통신은 됐고 값이 없다 — 재시도로 풀릴 문제가 아니라 콘솔 설정 문제다.
            reportKeyUnavailable(reason: "console_no_key")
            return
        }

        positioningLicense = key
        // ⚠️ 주입받은 session 을 그대로 물려준다 — 안 그러면 `.shared` 로 떨어져 테스트의
        // 스텁 세션을 우회하고 실제 서비스로 요청이 나간다(I3).
        // 콘솔 조회는 initialize(baseURL:) 로 받은 주소로 간다 — 예전엔 prod 주소를 박아 써서 자체
        // 서버·스테이징 고객의 건물·층·구역 조회가 prod 로 나갔다(S15).
        spaceClient = SpaceServiceClient(keys: .init(sdk: api.apiKey, space: key),
                                         consoleBaseURL: api.baseURL,
                                         session: session)
    }

    /// 측위 키를 못 구했다는 사실을 남긴다. reason 은 고정 토큰이라 키 값이 실리지 않는다.
    func reportKeyUnavailable(reason: String) {
        report(.keyUnavailable, "reason=\(reason)", message: SdkLocalized.text("coord.keyUnavailable"))
    }

    // MARK: - 공간 조회 (엔드포인트 하나당 메서드 하나 — 공간 서비스 키를 못 구했으면 빈 값)

    func buildings() async throws -> [Building] {
        guard let spaceClient else { return [] }
        return try await spaceClient.loadBuildings()
    }

    func floors(buildingId: String) async throws -> [Floor] {
        guard let spaceClient else { return [] }
        return try await spaceClient.loadFloors(buildingId: buildingId)
    }

    /// 층 단건 — 도면 이미지 포함.
    func floor(buildingId: String, floorId: String) async throws -> Floor {
        guard let spaceClient else { throw SdkError.notInitialized }
        return try await spaceClient.loadFloor(buildingId: buildingId, floorId: floorId)
    }

    func zones(buildingId: String, floorId: String) async throws -> [Zone] {
        guard let spaceClient else { return [] }
        return try await spaceClient.loadZones(buildingId: buildingId, floorId: floorId)
    }

    /// ⚠️ 조회 실패는 던지지 않는다 — 빈 목록으로 떨어져 `positioningReady` 가 거짓이 된다.
    /// 로케이터를 못 받았다고 지도(도면·존)를 통째로 지울 이유가 없다. 이유는 setFloorMap 이
    /// 코드로 남긴다(E3006). `throws` 는 초기화 전 호출(notInitialized) 때문에 남는다.
    func locators(buildingId: String, floorId: String) async throws -> FloorLocators {
        guard let spaceClient else { throw SdkError.notInitialized }
        return await spaceClient.loadLocators(buildingId: buildingId, floorId: floorId)
    }

    // MARK: - 층 지정

    /// 측위·판정에 쓸 층을 지정한다. 호출할 때마다 갱신되고, nil 이면 비운다.
    /// 가동 중에 부르면 즉시 층 전환 — 세션은 그대로, 엔진 주입값만 갈린다.
    func setFloorMap(_ floor: Floor?, buildingId: String?) async throws {
        let previousFloor = floorState
        guard let floor, let buildingId else {
            floorState = nil
            currentFloor = nil
            provider?.apply(config: PositioningConfig())   // 엔진에서 층 설정 해제
            restartLiveStreamIfFloorChanged(previousFloor: previousFloor)
            return
        }
        guard let spaceClient else { throw SdkError.notInitialized }
        let state = try await spaceClient.loadFloorState(buildingId: buildingId, floorId: floor.id)
        floorState = state
        currentFloor = floor
        // ⚠️ 예전에는 여기서 `coord.floorLoaded`("zones %d개")를 썼는데 넘기는 값은 **로케이터 수**였다.
        //    로그만 보면 "존이 4개 있다" 로 읽혀, 실제로는 존이 0개인 상황을 정반대로 해석하게 된다
        //    (2026-09-10 장애 분석에서 실제로 이 줄 때문에 원인을 한참 헤맸다). 둘 다 이름을 붙여 찍는다.
        report(.floorSet, "building=\(buildingId) floor=\(floor.id) " +
                          "locators=\(state.locators.count) zones=\(state.zones.count)",
               message: SdkLocalized.format("coord.floorLoaded", state.locators.count, state.zones.count,
                                            String(floor.id.prefix(8))))
        // 측위가 실제로 가능한 상태인지 — 관리자가 콘솔에서 원인을 바로 볼 수 있게 코드로 남긴다
        // "못 받았다"(E3006)와 "안 깔았다"(E3002)를 가른다 — 확인할 곳이 다르다.
        // 앞은 연동·네트워크, 뒤는 현장이다. 둘을 뭉치면 엉뚱한 데를 뒤지게 된다.
        // ⚠️ 어느 쪽이든 **도면·존 표시는 막지 않는다** — 여기까지 왔다는 건 층이 열렸다는 뜻이다.
        if state.locatorsFetchFailed { report(.locatorsFetchFailed, "floor=\(floor.id)") }
        else if state.locators.isEmpty { report(.locatorsMissing, "floor=\(floor.id)") }
        if state.sessionId == nil { report(.sessionIdMissing, "floor=\(floor.id)") }
        if state.zones.isEmpty    { report(.zonesEmpty,      "floor=\(floor.id)") }
        // 도면 없음은 실패가 아니다 — 지도를 배경 없이 그려야 한다는 사실만 남긴다.
        // 관리자가 "지도가 왜 비어 있나"를 로그 한 줄로 알 수 있게 코드로 찍는다.
        if !state.hasPlan         { report(.planMissing,     "floor=\(floor.id)") }
        if isRunning { applyFloorStateToProvider() }      // 가동 중 층 전환
        restartLiveStreamIfFloorChanged(previousFloor: previousFloor)
    }

    /// 존만 재조회 (도면 재다운로드 없음 — 폴링용). 받은 존은 엔진에도 즉시 반영.
    /// 실패하면 지금 존을 그대로 돌려준다 — 통신 오류로 지도의 존이 사라지면 안 된다.
    /// 로그는 "결과가 바뀔 때만" — 등록 감시가 1초마다 부르는 경로라 매번 찍으면 로그창이 덮인다.
    func refreshZones() async -> [Zone] {
        guard let spaceClient, let state = floorState else {
            logZoneOutcome(.warn, SdkLocalized.text("zone.refreshSkipped"), key: "no-floor")
            return floorState?.zones ?? []
        }
        do {
            let zones = try await spaceClient.loadZones(buildingId: state.buildingId,
                                                     floorId: state.floorId)
            // ⚠️ 기다리는 사이 층이 바뀌었으면 이 결과는 옛 층의 것이다 — 쓰지 않는다.
            //    예전엔 확인 없이 floorState 에 넣어, 5초 폴링과 setFloorMap(B) 가 겹치면 B 층에
            //    A 층 구역이 들어갔다(지도·판정 모두 — 2026-10-02 감사 S10).
            guard let now = floorState, now.buildingId == state.buildingId,
                  now.floorId == state.floorId else {
                return floorState?.zones ?? []
            }
            let changed = Self.geofencesChanged(from: now.zones, to: zones)
            let modified = now.zones != zones
            floorState?.zones = zones
            // 구역을 전부 지웠을 때도 엔진에 반영해야 한다 — 안 그러면 판정 엔진이 삭제된 구역을
            // 계속 물고 있어 지도에서 사라진 자리에서 없어진 시책이 계속 발화한다.
            // ⚠️ **바뀌었을 때만** 넣는다. 넣을 때마다 판정기가 초기화돼 체류 타이머가 지워지므로,
            //    5초마다 새로고침하는 앱(온보딩 앱)은 dwell_seconds 가 5초를 넘는 체류 시책을 영영
            //    못 받았다(S11).
            if isRunning, modified {
                provider?.apply(config: PositioningConfig(zones: zones))
                // ⚠️ 위 apply 만으로는 **판정이 안 바뀐다.** 측위 엔진은 지오펜스를 자기 서버에서
                //    받아 start() 때 한 번만 읽는다(주입한 존은 zone_id 매핑·진단용). 그래서
                //    영역이 바뀐 순간 엔진을 다시 읽게 해야 한다 — 안 하면 새로 그린 구역은
                //    지도에만 보이고 진입·이탈이 영원히 안 나온다(2026-09-10 실기기 확인:
                //    PRM 로그에 `영역 추가` 가 start 시점에만 찍힌다).
                //
                //    **바뀐 순간에만** 부른다. 이 경로는 앱이 5초마다 폴링하는 자리라, 매번
                //    부르면 엔진이 계속 껐다 켜져 측위가 아예 서지 않는다.
                if changed {
                    log(.warn, SdkLocalized.format("zone.geofenceReload", zones.count))
                    provider?.reloadGeofences()
                }
            }
            let names = zones.map(\.name).joined(separator: ", ")
            logZoneOutcome(.info, zones.isEmpty ? SdkLocalized.text("zone.refreshEmpty")
                                         : SdkLocalized.format("zone.refreshOk", zones.count, names),
                           key: "ok:\(names)")
            return zones
        } catch {
            logZoneOutcome(.error, SdkLocalized.format("zone.refreshFail", state.zones.count, "\(error)"),
                           key: "err:\(error)")
            return state.zones
        }
    }

    /// 엔진이 지오펜스를 다시 읽어야 하는가 — **어느 구역이 있느냐**만 본다.
    ///
    /// 이름·폴리곤이 아니라 id 집합으로 비교한다. 구역을 다시 그리면 콘솔이 새 id 를 주므로
    /// (실측: `020461cd…` → `258dae1e…`) 도형이 바뀐 경우도 여기서 잡힌다. 반대로 id 가 같으면
    /// 엔진이 이미 그 구역을 물고 있으니 다시 읽힐 이유가 없다.
    static func geofencesChanged(from old: [Zone], to new: [Zone]) -> Bool {
        Set(old.map(\.id)) != Set(new.map(\.id))
    }

    /// 직전과 결과가 같으면 침묵 (폴링 도배 방지). 호스트가 버튼으로 부른 건 앱이 따로 남긴다.
    private var lastZoneOutcome: String?
    private func logZoneOutcome(_ message: String, key: String) {
        logZoneOutcome(.log, message, key: key)
    }
    private func logZoneOutcome(_ level: LogLevel, _ message: String, key: String) {
        guard lastZoneOutcome != key else { return }
        lastZoneOutcome = key
        log(level, message)
    }

    /// floorState → provider (로케이터·세션·존 + 건물·층 ID)
    private func applyFloorStateToProvider() {
        guard let state = floorState, let provider else { return }
        provider.apply(buildingId: state.buildingId, floorId: state.floorId)
        var anchorMap: [Int: SIMD3<Double>] = [:]
        for l in state.locators { anchorMap[l.address] = SIMD3(l.x, l.y, l.z) }
        provider.apply(config: PositioningConfig(anchors: anchorMap,
                                                 sessionId: state.sessionId,
                                                 zones: state.zones))
    }

    /// 시작(매장 진입 시) — 측위 가동. 서버 왕복 없음 (prepare 가 미리 끝나 있다).
    func start(provider: PositioningProvider) async throws {
        // 내려가는 중이면 그 정지가 끝나기를 기다렸다가 이어서 켠다.
        // (UwbPositioningProvider 가 엔진에 대해 하는 것과 같은 대우를 세션에도 준다.)
        if let stopping = stopInFlight { await stopping.value }
        guard !isRunning else {                                      // 멱등
            // ⚠️ 조용히 돌아가지 않는다. 여기서 삼킨 start 하나 때문에 화면은 「찾는 중」인데
            //    실제로는 아무것도 안 도는 상태가 되고, 그 사실이 어디에도 안 남았다.
            log(.warn, SdkLocalized.text("coord.startIgnored"))
            return
        }
        guard isPrepared else { throw SdkError.notInitialized }
        _ = try requireUserId()                                      // 인증이 앞에 있어야 한다

        // 층 상태 주입 — setFloorMap 으로 받아둔 층(로케이터·세션·존)이 있을 때만.
        // 층 미지정이면 측위 파이프라인은 돌되 좌표가 나오지 않는다 → 조용히 두지 않고 알린다.
        self.provider = provider
        if floorState != nil {
            applyFloorStateToProvider()
        } else {
            // 엔진이 BLE 로 층을 찾는 흐름에서는 **여기가 정상 경로다** — 서버에 E3001 을 올리지 않는다.
            // 예전엔 시작할 때마다 올라가(0.1.19 에 ERROR→WARN 으로만 내렸다) 콘솔 로그가 이 줄로
            // 덮였다(2026-10-02). 층이 **끝내** 안 잡히는 것은 E3007 floorNotDetected 가 알린다.
            // 화면 로그(onDebugLog)에는 남긴다 — "왜 아직 좌표가 없지" 의 답이다.
            log(.info, SdkLocalized.text("coord.noFloorLoaded"))
        }

        // 방문 시작
        visitorId = identity.newVisitorId()
        report(.positioningOn, "visitor=\(visitorId)")
        // 새 세션은 일시정지 없이 시작한다 — provider 는 생명주기 재시작 때 일시정지를 유지하므로(S20)
        // 지난 세션의 일시정지가 남아 있을 수 있다.
        if provider.isPaused { provider.resume() }
        provider.delegate = self
        // ⚠️ isRunning 을 **먼저** 세운다. 엔진은 시작 안에서 동기로 접힐 수 있다(라이선스 없음·위치 권한이
        //    이미 거부됨) — 그 알림(didStopUnexpectedly)이 isRunning=false 일 때 오면 무시돼, 세션은
        //    「측위 중」 인 채 엔진만 죽은 상태로 남았다.
        isRunning = true
        provider.start()
        guard isRunning else { return }   // 시작 안에서 이미 닫혔다(재시도 불가) — 타이머를 걸지 않는다
        uploads.beginSession()
        startReceptionCheck()
        ensureLiveStream()
        observeAppLifecycleIfNeeded()
    }

    /**
     * 측위를 켠 뒤 한 번, 신호가 실제로 잡히고 있는지 본다.
     *
     * 로케이터가 죽어도 앱에서는 "좌표가 그냥 안 나온다" 로만 보인다. 원인을 현장에서
     * 특정할 유일한 온디바이스 단서가 이 비교(등록 vs 수신)라, 로그에 남겨 둔다.
     * 개발자는 Console.app 에서, 관리자는 콘솔 로그 분석기에서 같은 줄을 본다.
     *
     * ⚠️ **미수신을 고장으로 단정하지 않는다.** 앵커 세트는 마스터 1대와 서브 여러 대로
     * 이루어지고, 마스터가 살아 있는 한 서브가 빠져도 측위는 계속된다 — 감도가 떨어질 뿐이다.
     * 그래서 WARN 으로 남긴다: 지금 당장 막힌 것은 아니지만 손볼 것이 생겼다는 뜻이다.
     * ERROR 로 올리면 멀쩡한 현장에서 계속 울려 진짜 문제가 났을 때 아무도 안 본다.
     *
     * 한 번만 본다. 주기적으로 남기면 같은 줄이 로그를 덮어 정작 필요한 것이 묻힌다.
     */
    private func startReceptionCheck() {
        receptionCheckTask?.cancel()
        receptionCheckTask = Task { [weak self] in
            try? await Task.sleep(seconds: self?.receptionCheckDelay ?? 0)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            guard let d = self.provider?.positioningDiagnostic else { return }   // 진단 없는 provider

            // ⚠️ 아래 두 갈래를 하나로 합치지 말 것. 앵커별 상태를 못 주는 엔진에서는
            //    missing 이 항상 비고 matched 가 항상 0 이라, 예전 조건(`!missing.isEmpty`,
            //    `matched >= 3`)이 **둘 다 영원히 거짓**이 되어 좌표가 안 나와도 아무 로그가
            //    안 남았다. 코드는 그대로 돌아서 눈에 띄지도 않는다.
            if d.canAttributePerAnchor {
                if !d.missingAddresses.isEmpty {
                    // 마스터가 빠졌는지 서브가 빠졌는지는 SDK 가 알 수 없다(주소만 안다).
                    // 그래서 판정하지 않고 사실만 적는다 — 판단은 현장 기기 라벨과 대조해야 한다.
                    report(.locatorNotReceived,
                           "registered=\(d.registeredCount) received=\(d.receivedCount) missing=\(d.missingLabel)")
                }
                // 신호는 충분히 잡히는데 좌표가 안 나오면 등록 좌표와 실제 배치가 어긋났을 수 있다.
                // 이건 측위가 실제로 막힌 상태라 ERROR 다.
                if !d.hasFix && d.matchedCount >= 3 {
                    report(.noPositionFix, "matched=\(d.matchedCount) fix=none")
                }
            } else {
                // 앵커별 특정 불가 — 물을 수 있는 것은 "좌표가 나오는가" 하나뿐이다.
                // 등록된 로케이터가 있는데 좌표가 없으면 그 사실만 남긴다. 원인(미수신인지
                // 좌표계 불일치인지)은 못 가르므로 단정하지 않고 문맥에 한계를 적어 둔다.
                if !d.hasFix && d.registeredCount > 0 {
                    report(.noPositionFix,
                           "registered=\(d.registeredCount) fix=none (per-anchor detail unavailable)")
                }
            }
        }
    }

    /// 프로필 연결 — 좌표·존 이벤트가 이 ID 로 귀속된다.
    func identify(profileId: String?) {
        self.profileId = profileId
        reporter.profileId = profileId
        guard profileId != nil else { return }
        report(.identified)
        // 프로필이 없던 동안 붙들어 둔 로그(초기화 중 E1007 등)를 이제 보낸다(S13).
        Task { await self.reporter.flush() }
    }

    // MARK: - 프로필 CRUD (키 검증 통과가 전제라 coordinator 경유)

    func createProfile(_ attributes: [String: String]) async throws -> String {
        try await api.createProfile(ReqProfile(attributes: attributes)).profile_id
    }
    func getProfile(_ profileId: String) async throws -> [String: String] {
        try await api.getProfile(profileId).attributes ?? [:]
    }
    func putProfile(_ profileId: String, _ attributes: [String: String]) async throws {
        _ = try await api.putProfile(profileId, ReqProfile(attributes: attributes))
    }
    func deleteProfile(_ profileId: String) async throws {
        _ = try await api.deleteProfile(profileId)
    }

    // MARK: - 버퍼 창구

    /// 쌓인 좌표를 지금 전송 (300건/60초를 기다리지 않고 앞당김)
    func sendNow() async { await uploads.flush() }
    /// 쌓인 좌표를 전송 없이 폐기
    func discardPending() { uploads.discard() }

    /// 진행 중인 정지 — `start` 는 이걸 기다렸다가 이어서 켠다.
    ///
    /// ⚠️ 이 한 줄이 없어서 **[측위 종료] 뒤 재시작이 영영 안 살아났다**(2026-09-10 실기기).
    ///    `stop()` 은 잔여 좌표를 서버로 flush 하느라 `await` 하고, `isRunning = false` 는
    ///    그 왕복이 끝난 뒤에야 세운다(현장 로그에서 157ms). 종료 직후에 오는 `start()` 는
    ///    그 창에 정확히 들어가 `guard !isRunning` 에 걸렸고, **아무 로그도 남기지 않고**
    ///    돌아갔다 — 앱에는 "세션 id 는 발급됐는데 엔진 시작 줄이 없다" 로만 보였다.
    private var stopInFlight: Task<Void, Never>?

    /// 종료: 측위 정지 + 잔여 좌표 flush (도식 11)
    ///
    /// 이미 내려가는 중이면 그 정지에 합류한다 — 두 번 끄지 않는다.
    func stop(reason: FloorSession.StopReason = .ended) async {
        if let running = stopInFlight { await running.value; return }
        guard isRunning else { return }
        let task = Task { @MainActor in await self.performStop(reason: reason) }
        stopInFlight = task
        await task.value
        stopInFlight = nil
    }

    private func performStop(reason: FloorSession.StopReason) async {
        supervisor.reset()
        // 끝낸 세션에 일시정지를 남기지 않는다 — 다음 begin() 은 항상 정상 상태로 시작한다.
        if provider?.isPaused == true { provider?.resume() }
        provider?.stop()
        uploads.endSession()
        receptionCheckTask?.cancel(); receptionCheckTask = nil
        log(SdkLocalized.format("coord.stopFlush", uploads.pendingCount))
        await uploads.flush()
        if uploads.pendingCount > 0 {
            report(.pendingDropped, "points=\(uploads.pendingCount)",
                   message: SdkLocalized.format("coord.pendingLost", uploads.pendingCount))
        }
        report(.positioningOff, "visitor=\(visitorId)")
        await reporter.flush()           // 세션 종료 — 잔여 로그도 내보낸다
        isRunning = false
        // 층을 계속 보고 있으면 스트림은 그대로 둔다 — 측위를 껐다고 콘솔 변경까지
        // 안 받을 이유는 없다. 관찰자도 그래서 남긴다(reset 에서 정리).
        // ⚠️ isRunning=false **뒤에** 판단한다. 예전엔 앞에서 판단해 "측위 중" 으로 읽혔고, 층을 안 정한
        //    채 end() 해도 실시간 연결·생명주기 관찰이 남았다(S18).
        ensureLiveStream()
        if !liveStreamWanted { removeLifecycleObservers() }
        // 앱에 알린다 — 엔진이 포기해 닫힌 세션을 앱이 모르면 화면은 「찾는 중」 에 머문다(S6).
        onSessionClosed?(reason)
    }

    // MARK: - 실시간 수신 (SSE)

    /// 스트림이 붙어 있어야 하는가 — **층이 정해졌거나 측위가 도는 동안**(LiveStreamController.streamWanted).
    private var liveStreamWanted: Bool {
        Self.streamWanted(floorSet: floorState != nil, running: isRunning)
    }

    static func streamWanted(floorSet: Bool, running: Bool) -> Bool {
        LiveStreamController.streamWanted(floorSet: floorSet, running: running)
    }

    /// 필요하면 붙이고, 필터가 그대로면 아무것도 하지 않는다(멱등).
    private func ensureLiveStream() {
        liveStream.ensure(wanted: liveStreamWanted, floor: floorState)
    }

    /// 실시간 연결이 붙어 있는가 — 테스트가 수명을 확인한다.
    var isLiveStreamAttached: Bool { liveStream.isAttached }
    /// 내려가는 중인가(stop 이 잔여 좌표를 보내며 기다리는 동안).
    var isStopping: Bool { stopInFlight != nil }

    /// 코디네이터를 버리기 전 정리. stop() 은 층이 남아 있으면 스트림을 일부러 살려 두므로,
    /// 참조를 놓는 쪽에서 이걸 부르지 않으면 열린 연결이 다음 재연결 회차까지 남는다.
    func teardown() {
        liveStream.detach()
        removeLifecycleObservers()
    }

    /// 콘솔 변경을 고객사에게 넘긴다 — 스트림이 부르는 운영 경로다(옛 이름 …ForTest, 감사 K10).
    func deliverConfigChange(_ change: ConfigChange) {
        // 도면 캐시만은 SDK 가 지운다 — 앱이 floor() 를 다시 불러도 캐시가 옛 도면을 주면 앱이 할 수
        // 있는 일이 없다(재초기화 전까지 — S16). 재동기화는 그 사이 도면이 바뀌었을 수 있다는 뜻이다.
        switch change {
        case .planChanged(let floorId): spaceClient?.invalidatePlan(floorId: floorId)
        case .resyncNeeded:             spaceClient?.invalidatePlan(floorId: nil)
        default: break
        }
        onConfigChange?(change)
    }

    /// setFloorMap 이 건물·층을 실제로 바꿨을 때만 스트림을 다시 붙인다(측위 중이 아니어도 —
    /// 층을 띄워 둔 동안에도 콘솔 변경을 받아야 한다).
    ///
    /// 재연결 자체가 LiveConfigStream 안에서 .resyncNeeded 를 올린다. 이건 부작용이 아니라
    /// 의도다 — 층이 바뀌면 고객사는 어차피 새 층 기준으로 다시 받아야 한다.
    ///
    /// 층을 비우는 것(setFloorMap(nil, ...))도 "바뀜"으로 센다. 세션이 끝난 게 아니라 다음 층을
    /// 고르는 중일 수 있어, 스트림을 멈추지 않고 테넌트 전체 필터(nil)로 계속 받는다 —
    /// 그래야 다음 setFloorMap 전까지 놓치는 변경이 없다.
    private func restartLiveStreamIfFloorChanged(previousFloor: FloorState?) {
        guard floorFilterChanged(from: previousFloor, to: floorState) else { return }
        observeAppLifecycleIfNeeded()   // 측위 없이 층만 봐도 배경 전환을 다뤄야 한다
        ensureLiveStream()
    }

    /// 스트림이 다시 구독해야 할 만큼 건물·층이 바뀌었는지 — 네트워크가 없는 순수 판정이라
    /// 유닛 테스트로 그대로 검증한다. buildingId·floorId 만 본다: 같은 층이면 zones 등
    /// 나머지 필드가 바뀌어도 구독 자체는 바뀔 이유가 없다(그건 refreshZones() 의 몫).
    func floorFilterChanged(from previous: FloorState?, to next: FloorState?) -> Bool {
        LiveStreamController.filterChanged(from: previous, to: next)
    }

    // MARK: - verify 재료

    private static var appId: String? { Bundle.main.bundleIdentifier }

    /// profileId 가 없으면 세션이 성립하지 않는다 — 데이터에 주인이 없으면 리포트가 성립하지 않는다.
    private func requireUserId() throws -> String {
        guard let profileId, !profileId.isEmpty else { throw SdkError.notIdentified }
        return profileId
    }

    private func makeVerifyRequest() -> ReqVerify {
        ReqVerify(platform_name: SdkPlatform.name, app_id: Self.appId)
    }

    private func observeAppLifecycleIfNeeded() {
        #if canImport(UIKit)
        guard lifecycleObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        lifecycleObservers = [
            // 백그라운드: UWB는 어차피 정지(포그라운드 전용) → 엔진 정지 + 잔여 flush (일시정지는 유지)
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // 내려가면 다시 켜 보기를 멈춘다 — 백그라운드에선 UWB 가 안 돈다. 돌아오면 아래에서 켠다.
                    self.supervisor.cancel()
                    if self.isRunning {                 // 측위는 세션이 돌 때만
                        self.provider?.stop()
                        await self.uploads.flush()
                    }
                    self.liveStream.suspend()           // 스트림은 언제나 끊는다
                }
            },
            // 포그라운드 복귀: 측위 재개 + 실시간 수신 재연결
            // 재연결 자체가 LiveConfigStream 쪽에서 .resyncNeeded 를 올린다 — 배경에 있던
            // 동안의 변경을 고객사가 따라잡는 유일한 경로다.
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // 복귀는 새 기회다 — 내려가기 전의 재시도 횟수는 잊는다. 이 시작이 접히면
                    // provider 가 didStopUnexpectedly 로 알려 오고, 거기서 다시 켜 보거나 세션을 닫는다.
                    self.supervisor.resetAttempts()
                    // 내려가는 중(stop 이 잔여 좌표를 보내며 기다리는 동안)이면 켜지 않는다 — 끝난 세션에서
                    // 엔진이 다시 돌며 옛 방문 ID 로 존 이벤트를 보내게 된다(S9).
                    if self.isRunning, self.stopInFlight == nil { self.provider?.start() }
                    self.liveStream.forgetConnection()  // 배경에서 끊긴 것 — 새로 붙인다
                    self.ensureLiveStream()
                }
            },
        ]
        #endif
    }

    /// 앱이 화면에 떠 있는가 — 테스트가 바꿔 끼운다(EngineSupervisor 가 재시도 전에 본다).
    var isAppActive: () -> Bool {
        get { supervisor.isAppActive }
        set { supervisor.isAppActive = newValue }
    }

    private func removeLifecycleObservers() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers = []
    }

    // MARK: - ISO-8601 (UTC, 밀리초 — 사양서 §3)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
}

// MARK: - PositioningProviderDelegate (도식 6~9)

extension SessionCoordinator: PositioningProviderDelegate {

    /// 엔진이 층을 잡았다/잃었다 — 앱에 그대로 넘긴다(층 고르기는 앱의 몫).
    func provider(_ p: PositioningProvider, didDetectFloor floorId: String?) {
        guard provider === p else { return }
        onFloorDetected?(floorId)
    }

    /// 앱에 보일 구역 이벤트 — 세션이 도는 동안만.
    func provider(_ p: PositioningProvider, didEmit event: ZoneEvent) {
        guard isLiveSession(p) else { return }
        onZoneEvent?(event)
    }

    /// 엔진 진단 → 표준 경로(onDebugLog + 서버 E-코드). 어댑터가 화면 로그로만 남기면
    /// 콘솔 로그 분석기에서 안 보인다 — 코드로 올려야 관리자가 현장 없이 원인을 짚는다.
    func provider(_ p: PositioningProvider, didReport code: SdkErrorCode, context: String) {
        report(code, context)
    }

    /// 엔진이 스스로 꺼졌다 — 다시 켜 보거나(포그라운드·재시도 가능·횟수 남음), 세션을 닫는다.
    ///
    /// ⚠️ 그대로 두지 않는다. 세션이 "측위 중" 인 채 엔진만 죽어 있으면 앱의 `begin()` 이 삼켜지고,
    ///    화면은 「찾는 중」인데 아무것도 안 도는 상태가 앱을 껐다 켤 때까지 간다.
    func provider(_ p: PositioningProvider, didStopUnexpectedly retryable: Bool, context: String) {
        guard isRunning, stopInFlight == nil, provider === p else { return }
        supervisor.handleUnexpectedStop(p, retryable: retryable, context: context,
                                        isLive: { [weak self] p in self?.isLiveSession(p) ?? false },
                                        giveUp: { [weak self] in
            Task { await self?.stop(reason: .engineFailed) }
        })
    }

    /// 좌표 fix — 버퍼 적재, 임계에 **닿는 순간** flush
    func provider(_ p: PositioningProvider, didUpdate coordinates: Coordinates,
                  floorId: String, at capturedAt: Date) {
        guard isLiveSession(p) else { return }
        supervisor.resetAttempts()        // 다시 살아났다 — 다음 고장은 처음부터 센다
        onPosition?(coordinates)          // 앱 훅 — 원속도 유지 (지도 렌더)
        // ⚠️ 서버 전송분만 솎는다. 존 판정(엔진)은 원속도 그대로 — 여기서 솎으면 판정 입력이 줄어든다.
        uploads.record(coordinates, floorId: floorId, at: capturedAt)
    }

    /// 지금 이 provider 의 좌표·판정을 받아도 되는가 — 세션이 돌고 있고, 내려가는 중이 아니고,
    /// 지금 물린 provider 가 보낸 것일 때만.
    ///
    /// 종료(stop)는 잔여 좌표를 보내느라 기다리는 동안 isRunning 을 true 로 둔다. 그 창에 늦게 온
    /// 존 판정이 끝난 세션의 방문 ID 로 나가지 않게 막는다(S9).
    private func isLiveSession(_ p: PositioningProvider) -> Bool {
        isRunning && stopInFlight == nil && provider === p
    }

    /// 존 판정 — 즉시 전송 (network 실패만 1회 재시도), triggers는 호스트 콜백으로
    func provider(_ p: PositioningProvider, didDetectZone zoneId: String,
                  status: ZoneEventStatus, floorId: String, at occurredAt: Date) {
        guard isLiveSession(p), let profileId else { return }
        let req = ReqZoneEvent(profile_id: profileId,
                               visitor_id: visitorId,
                               floor_id: floorId,
                               zone_id: zoneId,
                               status: status,
                               occurred_at: Self.iso(occurredAt),
                               platform_name: SdkPlatform.name)
        Task {
            do {
                let res = try await api.sendZoneEvent(req)
                log(SdkLocalized.format("coord.zoneSent", status.rawValue, res.triggers.count))
                onTriggers?(zoneId, res.triggers)
            } catch ApiError.network {
                // 소량 재시도 (사양서 §9) — 1회만, 그래도 실패면 드랍 (인메모리 v1)
                if let res = try? await api.sendZoneEvent(req) {
                    log(.info, SdkLocalized.format("coord.zoneRetryOK", status.rawValue))
                    onTriggers?(zoneId, res.triggers)
                } else {
                    report(.network, "zone=\(zoneId) status=\(status.rawValue) dropped",
                           message: SdkLocalized.format("coord.zoneDropNet", status.rawValue))
                }
            } catch {
                reporter.reportApi(error, "zone=\(zoneId) status=\(status.rawValue) dropped",   // 서버 500이면 여기
                                   message: SdkLocalized.format("coord.zoneDropErr", status.rawValue))
            }
        }
    }
}
