//
//  SessionCoordinator.swift
//  라이프사이클 상태기계 (사양서 §5) — SDK의 두뇌
//
//  verify(키검증) → buildings(1회) → provider 가동
//    ├ didEnter(빌딩)   → buildings 캐시 보정
//    ├ didUpdate(좌표)  → 층 설정 lazy 로드 + 버퍼 적재 → 300건/60초/종료/백그라운드에 벌크 전송
//    └ didDetectZone    → events/zone 즉시 전송 (+network 1회 재시도) → triggers 호스트 전달
//
//  · 동의 게이팅: consent=false면 수집 미시작 (결정사항 5 — 서버는 기록만 하므로 클라가 막음)
//  · 백그라운드: UWB 포그라운드 전용(결정사항 6) → pause+flush, 복귀 시 재개
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
    private var geospace: GeospaceClient?        // initialize(geoSdkKey:)가 있을 때만 — 앵커·세션·층 (과도기)
    private var provider: PositioningProvider?   // start(consent:provider:)에서 장착

    // 배치 정책 (사양서 §6.8 은 100건/5분 "권장" — 2026-08-20 300건/60초로 조정.
    // 4Hz 에서는 300건(=75초)보다 60초 타이머가 먼저 걸려 실질 60초·240건 주기가 된다.
    // 종전 100건/300초는 25초마다 100건 → 요청 수가 2.4배였다. 테스트에서 작게 주입.)
    private let flushThreshold: Int
    private let flushInterval: TimeInterval
    private(set) var buffer: TrajectoryBuffer!

    // 상태
    private(set) var isPrepared = false           // initialize(=prepare) 성공 여부 = "세션 가능"
    private(set) var isRunning = false
    private(set) var visitorId = ""
    /// 앱이 넘긴 프로필 ID — 좌표·존 이벤트의 귀속 키
    private(set) var profileId: String?

    // 서버가 verify 로 내려주는 테넌트 설정
    private(set) var positionRateHz = SdkDefaults.positionRateHz
    private(set) var remoteConfig: [String: String] = [:]
    /// 서버 전송용 좌표 다운샘플 기준 시각 — 판정 입력은 솎지 않는다
    private var lastRecordedAt: Date?
    private(set) var floorConfigs: [String: ResFloorConfig] = [:]   // 층별 존 설정 (lazy)
    private var loadingFloors: Set<String> = []
    private(set) var floorState: FloorState?    // setFloorMap 결과 — start 시 provider 에 주입
    private(set) var currentFloor: Floor?        // setFloorMap 이 받은 Floor (floorSession 노출용)
    private var flushTimer: Timer?
    /// 수신 진단 1회 확인 — 측위 시작 후 이 시간 뒤에 본다.
    /// 7초는 데모 앱이 현장에서 쓰던 값이다(5초 자동진단 직후).
    private var receptionCheckTask: Task<Void, Never>?
    private let receptionCheckDelay: TimeInterval
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// 존 이벤트 응답의 개인화 액션 → 호스트 전달 (zoneId, triggers)
    var onTriggers: ((String, [Trigger]) -> Void)?

    /// 실시간 좌표 → 호스트 전달 (지도에 내 위치 찍기용 — 도면 로컬 미터)
    var onPosition: ((Coordinates) -> Void)?

    /// SDK 내부 활동 로그 (디버그) — verify·flush·zone 전송의 성공/실패를 호스트에 노출
    var onLog: ((String) -> Void)?
    private func log(_ msg: String) { onLog?(msg) }

    /// 콘솔 변경 → 고객사 전달. SDK 는 이 신호로 아무것도 하지 않는다 —
    /// 무엇을 다시 받을지는 앱이 정한다.
    var onConfigChange: ((ConfigChange) -> Void)?

    private var live: LiveConfigStream?

    // MARK: - 서버 로그 (콘솔 로그 분석기)

    private(set) var logBuffer: SdkLogBuffer!

    /// 에러를 남긴다 — onDebugLog(시스템 언어 문구) + 서버(코드 + 문맥).
    /// 서버로는 문구를 보내지 않는다: 읽는 사람이 기기 사용자가 아니라 관리자라
    /// 콘솔이 관리자 화면 언어로 렌더링해야 한다.
    func report(_ code: SdkErrorCode, _ context: String = "") {
        log("[\(code.rawValue)] \(code.summary)\(context.isEmpty ? "" : " — \(context)")")
        logBuffer?.add(SdkLogEntry(code: code.rawValue, level: code.level.rawValue,
                                   message: context, at: Self.iso(Date())))
    }

    /// 세션 추적용 정보 로그 — 에러가 아니다.
    func report(_ code: SdkInfoCode, _ context: String = "") {
        log("[\(code.rawValue)] \(code.summary)\(context.isEmpty ? "" : " — \(context)")")
        logBuffer?.add(SdkLogEntry(code: code.rawValue, level: SdkLogLevel.info.rawValue,
                                   message: context, at: Self.iso(Date())))
    }

    /// 서버 통신 실패를 코드로 옮겨 남긴다. ApiError 가 아니면 network 로 본다.
    func reportApi(_ error: Error, _ context: String = "") {
        let code = (error as? ApiError)?.code ?? .network
        report(code, context)
    }

    private func sendLogs(_ batch: [SdkLogEntry]) async -> Bool {
        // profileId 가 없으면 귀속할 곳이 없다 — 로그를 버린다(초기화 전 단계).
        guard let profileId else { return false }
        let req = ReqSdkLogs(profile_id: profileId, platform_name: "iOS",
                             sdk_version: OneS1ght.sdkVersion, entries: batch)
        return (try? await api.sendLogs(req)) != nil
    }

    init(api: ApiClient,
         identity: IdentityStore,
         geospace: GeospaceClient? = nil,
         flushThreshold: Int = 300,
         flushInterval: TimeInterval = 60,
         maxPerRequest: Int = 500,
         receptionCheckDelay: TimeInterval = 7) {
        self.receptionCheckDelay = receptionCheckDelay
        self.api = api
        self.identity = identity
        self.geospace = geospace
        self.flushThreshold = flushThreshold
        self.flushInterval = flushInterval
        self.buffer = TrajectoryBuffer(maxPerRequest: maxPerRequest) { [weak self] batch in
            await self?.sendPositions(batch) ?? false
        }
        self.logBuffer = SdkLogBuffer { [weak self] batch in
            await self?.sendLogs(batch) ?? false
        }
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

        // 키 검증 + 클라 등록 (consent는 아직 모름 → 생략, 서버 기존값 보존)
        // verify 성공 = 키 유효 + 백엔드 도달 가능 두 가지를 한 번에 확인한 것.
        let verified = try await api.verify(makeVerifyRequest())
        guard verified.valid, verified.positioning_enabled else {
            throw SdkError.positioningDisabled
        }
        // 테넌트 설정 반영 — 범위 밖·미회신은 기본값(4Hz)으로 접는다
        let hz = verified.position_rate_hz ?? SdkDefaults.positionRateHz
        positionRateHz = min(max(hz, SdkDefaults.minRateHz), SdkDefaults.maxRateHz)
        remoteConfig = verified.remote_config ?? [:]
        log(SdkLocalized.format("coord.verifyPass", verified.tenant_code ?? "?"))
        report(.initialized, "tenant=\(verified.tenant_code ?? "?")")
        if positionRateHz != SdkDefaults.positionRateHz {
            log(SdkLocalized.format("coord.rateApplied", positionRateHz))
            report(.rateApplied, "rate=\(positionRateHz)")
        }
        isPrepared = true
    }

    // MARK: - 공간 조회 (엔드포인트 하나당 메서드 하나 — geoSdkKey 없으면 빈 값)

    func buildings() async throws -> [Building] {
        guard let geospace else { return [] }
        return try await geospace.loadBuildings()
    }

    func floors(buildingId: String) async throws -> [Floor] {
        guard let geospace else { return [] }
        return try await geospace.loadFloors(buildingId: buildingId)
    }

    /// 층 단건 — 도면 이미지 포함.
    func floor(buildingId: String, floorId: String) async throws -> Floor {
        guard let geospace else { throw SdkError.notInitialized }
        return try await geospace.loadFloor(buildingId: buildingId, floorId: floorId)
    }

    func zones(buildingId: String, floorId: String) async throws -> [Zone] {
        guard let geospace else { return [] }
        return try await geospace.loadZones(buildingId: buildingId, floorId: floorId)
    }

    func locators(buildingId: String, floorId: String) async throws -> FloorLocators {
        guard let geospace else { throw SdkError.notInitialized }
        return try await geospace.loadLocators(buildingId: buildingId, floorId: floorId)
    }

    // MARK: - 층 지정

    /// 측위·판정에 쓸 층을 지정한다. 호출할 때마다 갱신되고, nil 이면 비운다.
    /// 가동 중에 부르면 즉시 층 전환 — 세션은 그대로, 엔진 주입값만 갈린다.
    func setFloorMap(_ floor: Floor?, buildingId: String?) async throws {
        guard let floor, let buildingId else {
            floorState = nil
            currentFloor = nil
            provider?.apply(config: PositioningConfig())   // 엔진에서 층 설정 해제
            return
        }
        guard let geospace else { throw SdkError.notInitialized }
        let state = try await geospace.loadFloorState(buildingId: buildingId, floorId: floor.id)
        floorState = state
        currentFloor = floor
        log(SdkLocalized.format("coord.floorLoaded", state.locators.count, String(floor.id.prefix(8))))
        report(.floorSet, "building=\(buildingId) floor=\(floor.id) " +
                          "locators=\(state.locators.count) zones=\(state.zones.count)")
        // 측위가 실제로 가능한 상태인지 — 관리자가 콘솔에서 원인을 바로 볼 수 있게 코드로 남긴다
        if state.locators.isEmpty { report(.locatorsMissing, "floor=\(floor.id)") }
        if state.sessionId == nil { report(.sessionIdMissing, "floor=\(floor.id)") }
        if state.zones.isEmpty    { report(.zonesEmpty,      "floor=\(floor.id)") }
        if isRunning { applyFloorStateToProvider() }      // 가동 중 층 전환
    }

    /// 존만 재조회 (도면 재다운로드 없음 — 폴링용). 받은 존은 엔진에도 즉시 반영.
    /// 실패하면 지금 존을 그대로 돌려준다 — 통신 오류로 지도의 존이 사라지면 안 된다.
    /// 로그는 "결과가 바뀔 때만" — 등록 감시가 1초마다 부르는 경로라 매번 찍으면 로그창이 덮인다.
    func refreshZones() async -> [Zone] {
        guard let geospace, let state = floorState else {
            logZoneOutcome(SdkLocalized.text("zone.refreshSkipped"), key: "no-floor")
            return floorState?.zones ?? []
        }
        do {
            let zones = try await geospace.loadZones(buildingId: state.buildingId,
                                                     floorId: state.floorId)
            floorState?.zones = zones
            // 구역을 전부 지웠을 때도 엔진에 반영해야 한다 — 안 그러면 판정 엔진이 삭제된 구역을
            // 계속 물고 있어 지도에서 사라진 자리에서 없어진 시책이 계속 발화한다.
            if isRunning {
                provider?.apply(config: PositioningConfig(zones: zones))
            }
            let names = zones.map(\.name).joined(separator: ", ")
            logZoneOutcome(zones.isEmpty ? SdkLocalized.text("zone.refreshEmpty")
                                         : SdkLocalized.format("zone.refreshOk", zones.count, names),
                           key: "ok:\(names)")
            return zones
        } catch {
            logZoneOutcome(SdkLocalized.format("zone.refreshFail", state.zones.count, "\(error)"),
                           key: "err:\(error)")
            return state.zones
        }
    }

    /// 직전과 결과가 같으면 침묵 (폴링 도배 방지). 호스트가 버튼으로 부른 건 앱이 따로 남긴다.
    private var lastZoneOutcome: String?
    private func logZoneOutcome(_ message: String, key: String) {
        guard lastZoneOutcome != key else { return }
        lastZoneOutcome = key
        log(message)
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
        guard !isRunning else { return }                             // 멱등
        guard isPrepared else { throw SdkError.notInitialized }
        _ = try requireUserId()                                      // 인증이 앞에 있어야 한다

        // 층 상태 주입 — setFloorMap 으로 받아둔 층(로케이터·세션·존)이 있을 때만.
        // 층 미지정이면 측위 파이프라인은 돌되 좌표가 나오지 않는다 → 조용히 두지 않고 알린다.
        self.provider = provider
        if floorState != nil {
            applyFloorStateToProvider()
        } else {
            log(SdkLocalized.text("coord.noFloorLoaded"))
            report(.floorNotSet)
        }

        // 방문 시작
        visitorId = identity.newVisitorId()
        lastRecordedAt = nil
        report(.positioningOn, "visitor=\(visitorId)")
        provider.delegate = self
        provider.start()
        isRunning = true
        startFlushTimer()
        startReceptionCheck()
        startLiveStream()
        observeAppLifecycle()
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
            try? await Task.sleep(nanoseconds: UInt64(receptionCheckDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            guard let d = self.provider?.positioningDiagnostic else { return }   // 진단 없는 provider

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
        }
    }

    /// 프로필 연결 — 좌표·존 이벤트가 이 ID 로 귀속된다.
    func identify(profileId: String?) {
        self.profileId = profileId
        if profileId != nil { report(.identified) }
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
    func sendNow() async { await buffer.flush() }
    /// 쌓인 좌표를 전송 없이 폐기
    func discardPending() { buffer.empty() }

    /// 종료: 측위 정지 + 잔여 좌표 flush (도식 11)
    func stop() async {
        guard isRunning else { return }
        provider?.stop()
        flushTimer?.invalidate(); flushTimer = nil
        receptionCheckTask?.cancel(); receptionCheckTask = nil
        removeLifecycleObservers()
        live?.stop(); live = nil
        let pending = buffer.count
        log(SdkLocalized.format("coord.stopFlush", pending))
        await buffer.flush()
        if buffer.count > 0 {
            log(SdkLocalized.format("coord.pendingLost", buffer.count))
            report(.pendingDropped, "points=\(buffer.count)")
        }
        report(.positioningOff, "visitor=\(visitorId)")
        await logBuffer.flush()          // 세션 종료 — 잔여 로그도 내보낸다
        isRunning = false
    }

    // MARK: - 실시간 수신 (SSE)

    /// 콘솔 변경 수신 시작 — 측위 세션 구간에만 붙어 있는다.
    private func startLiveStream() {
        let s = LiveConfigStream(baseURL: api.baseURL, apiKey: api.apiKey)
        s.onLog = { [weak self] line in self?.log(line) }
        s.onChange = { [weak self] change in
            Task { @MainActor in self?.deliverConfigChangeForTest(change) }
        }
        s.start(buildingId: floorState?.buildingId, floorId: floorState?.floorId)
        live = s
    }

    /// 고객사에게 그대로 넘긴다. 이름에 ForTest 가 붙어 있지만 운영 경로도 이것을 쓴다 —
    /// 전달 외에 하는 일이 없어 분기할 이유가 없다.
    func deliverConfigChangeForTest(_ change: ConfigChange) {
        onConfigChange?(change)
    }

    // MARK: - 전송

    /// 좌표 벌크 전송 (buffer의 Sender) — true = 200
    private func sendPositions(_ batch: [PositionPoint]) async -> Bool {
        guard let profileId else { return false }
        let req = ReqPositionBulk(profile_id: profileId,
                                  visitor_id: visitorId,
                                  platform_name: "iOS",
                                  points: batch)
        do {
            let res = try await api.sendPositionLogs(req)
            log(SdkLocalized.format("coord.logsSent", batch.count, res.accepted_count))
            return true
        } catch {
            log(SdkLocalized.format("coord.logsFail", batch.count))
            reportApi(error, "positions=\(batch.count)")
            return false
        }
    }

    /// 층 설정 lazy 로드 — 처음 보는 floorId만 (사양서: 층 진입 시 해당 층만)
    private func ensureFloorLoaded(_ floorId: String) {
        guard floorConfigs[floorId] == nil, !loadingFloors.contains(floorId) else { return }
        loadingFloors.insert(floorId)
        Task {
            do {
                let config = try await api.floorConfig(floorId: floorId)
                floorConfigs[floorId] = config
                log(SdkLocalized.format("coord.floorLoaded", config.zones.count, String(floorId.prefix(8))))
            } catch ApiError.notFound {
                log(SdkLocalized.text("coord.floorEmpty"))
                // 404 = 이 층에 존 없음 → "정상 분기" (사양서 §9). 빈 설정으로 마킹해 재조회 방지
                floorConfigs[floorId] = ResFloorConfig(floor_id: floorId, building_id: nil,
                                                       name: floorId, synced_at: "",
                                                       zones: [], anchors: [])
            } catch {
                // 네트워크 등 — 마킹 안 함 → 다음 좌표에서 재시도
            }
            loadingFloors.remove(floorId)
        }
    }

    // MARK: - verify 재료

    private static var appId: String? { Bundle.main.bundleIdentifier }

    /// profileId 가 없으면 세션이 성립하지 않는다 — 데이터에 주인이 없으면 리포트가 성립하지 않는다.
    private func requireUserId() throws -> String {
        guard let profileId, !profileId.isEmpty else { throw SdkError.notIdentified }
        return profileId
    }

    private func baseClientInfo(_ profileId: String) -> ClientInfo {
        var c = ClientInfo(profile_id: profileId)
        c.sdk_version = OneS1ght.sdkVersion
        #if canImport(UIKit)
        c.os_name = "iOS"
        c.os_version = UIDevice.current.systemVersion
        #endif
        return c
    }

    private func makeVerifyRequest() -> ReqVerify {
        ReqVerify(platform_name: "iOS", app_id: Self.appId, client: nil)
    }

    // MARK: - 배치 트리거 (300건 / 60초 / 백그라운드)

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.buffer.flush() }
        }
    }

    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        lifecycleObservers = [
            // 백그라운드: UWB는 어차피 정지(포그라운드 전용) → 측위 pause + 잔여 flush
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.provider?.stop()
                    await self.buffer.flush()
                }
            },
            // 포그라운드 복귀: 측위 재개
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.provider?.start()
                }
            },
        ]
        #endif
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

    /// 입장 트리거 — 통지만 받는다. 건물·층 조회는 호스트 앱의 몫이라 SDK 는 움직이지 않는다.
    func provider(_ p: PositioningProvider, didEnter buildingId: String) {}

    /// 좌표 fix — 층 설정 확보 + 버퍼 적재, 임계 도달 시 flush
    func provider(_ p: PositioningProvider, didUpdate coordinates: Coordinates,
                  floorId: String, at capturedAt: Date) {
        onPosition?(coordinates)          // 앱 훅 — 원속도 유지 (지도 렌더)
        ensureFloorLoaded(floorId)
        // ⚠️ 서버 전송분만 솎는다. 존 판정(provider 내부 zoneEngine)은 원속도 그대로 —
        //    PRM 의 시간 게이트가 입력 간격을 전제로 동작해 여기까지 줄이면 체류·이탈이 어긋난다.
        guard shouldRecord(at: capturedAt) else { return }
        buffer.add(PositionPoint(floor_id: floorId,
                                 coordinates: coordinates,
                                 captured_at: Self.iso(capturedAt)))
        if buffer.count >= flushThreshold {
            Task { await buffer.flush() }
        }
    }

    /// position_rate_hz 다운샘플 판정.
    /// 경계에 10% 여유를 둔다 — 4Hz 설정에 4Hz 입력이면 간격이 0.25초 언저리로 흔들려,
    /// 정확히 1/rate 로 자르면 절반이 버려진다(기본값에서 동작이 바뀌면 안 된다).
    private func shouldRecord(at t: Date) -> Bool {
        let minGap = (1.0 / Double(positionRateHz)) * 0.9
        if let last = lastRecordedAt, t.timeIntervalSince(last) < minGap { return false }
        lastRecordedAt = t
        return true
    }

    /// 존 판정 — 즉시 전송 (network 실패만 1회 재시도), triggers는 호스트 콜백으로
    func provider(_ p: PositioningProvider, didDetectZone zoneId: String,
                  status: ZoneEventStatus, floorId: String, at occurredAt: Date) {
        ensureFloorLoaded(floorId)
        guard let profileId else { return }
        let req = ReqZoneEvent(profile_id: profileId,
                               visitor_id: visitorId,
                               floor_id: floorId,
                               zone_id: zoneId,
                               status: status,
                               occurred_at: Self.iso(occurredAt),
                               platform_name: "iOS")
        Task {
            do {
                let res = try await api.sendZoneEvent(req)
                log(SdkLocalized.format("coord.zoneSent", status.rawValue, res.triggers.count))
                onTriggers?(zoneId, res.triggers)
            } catch ApiError.network {
                // 소량 재시도 (사양서 §9) — 1회만, 그래도 실패면 드랍 (인메모리 v1)
                if let res = try? await api.sendZoneEvent(req) {
                    log(SdkLocalized.format("coord.zoneRetryOK", status.rawValue))
                    onTriggers?(zoneId, res.triggers)
                } else {
                    log(SdkLocalized.format("coord.zoneDropNet", status.rawValue))
                    report(.network, "zone=\(zoneId) status=\(status.rawValue) dropped")
                }
            } catch {
                log(SdkLocalized.format("coord.zoneDropErr", status.rawValue))   // 서버 500이면 여기 찍힘
                reportApi(error, "zone=\(zoneId) status=\(status.rawValue) dropped")
            }
        }
    }
}
