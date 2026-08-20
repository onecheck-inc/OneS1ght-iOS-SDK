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
    case notInitialized        // initialize() 안 하고 start() 호출
    case positioningDisabled   // verify는 통과했으나 positioning_enabled=false
    case consentRequired       // 동의 없음 → 수집 미시작
    case deviceNotSupported    // UWB 칩 없음 (측위 불가 기기)
    case osVersionTooLow       // iOS 27 미만
}

@MainActor
final class SessionCoordinator {

    // 의존성 (전부 주입 — 테스트는 스텁 세션·가짜 프로바이더)
    private let api: ApiClient
    private let identity: IdentityStore
    private var geospace: GeospaceClient?        // initialize(geospaceKey:)가 있을 때만 — 앵커·세션·층 (과도기)
    private var provider: PositioningProvider?   // start(consent:provider:)에서 장착

    // 배치 정책 (사양서 §6.8 은 100건/5분 "권장" — 2026-08-20 300건/60초로 조정.
    // 4Hz 에서는 300건(=75초)보다 60초 타이머가 먼저 걸려 실질 60초·240건 주기가 된다.
    // 종전 100건/300초는 25초마다 100건 → 요청 수가 2.4배였다. 테스트에서 작게 주입.)
    private let flushThreshold: Int
    private let flushInterval: TimeInterval
    private(set) var buffer: TrajectoryBuffer!

    // 상태
    private(set) var isPrepared = false           // initialize(=prepare) 성공 여부 = "세션 가능"
    /// 호스트가 loadFloor 를 호출한 적 있나 — **호출 진입 시점**에 세운다.
    /// 완료 시점(currentInfra)만 보면 자동 선택과 동시에 진행돼 늦게 끝난 쪽이 이기는 경합이 생긴다.
    private var hostDidSelectFloor = false
    private(set) var isRunning = false
    private(set) var visitorId = ""
    private(set) var floorConfigs: [String: ResFloorConfig] = [:]   // 층별 존 설정 (lazy)
    private var loadingFloors: Set<String> = []
    private var buildingsCache: ResBuildings?
    private(set) var currentInfra: FloorInfra?   // loadFloor 결과 — start 시 provider 에 주입
    private var flushTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// 존 이벤트 응답의 개인화 액션 → 호스트 전달 (zoneId, triggers)
    var onTriggers: ((String, [Trigger]) -> Void)?

    /// 실시간 좌표 → 호스트 전달 (지도에 내 위치 찍기용 — 도면 로컬 미터)
    var onPosition: ((Coordinates) -> Void)?

    /// SDK 내부 활동 로그 (디버그) — verify·flush·zone 전송의 성공/실패를 호스트에 노출
    var onLog: ((String) -> Void)?
    private func log(_ msg: String) { onLog?(msg) }

    init(api: ApiClient,
         identity: IdentityStore,
         geospace: GeospaceClient? = nil,
         flushThreshold: Int = 300,
         flushInterval: TimeInterval = 60,
         maxPerRequest: Int = 500) {
        self.api = api
        self.identity = identity
        self.geospace = geospace
        self.flushThreshold = flushThreshold
        self.flushInterval = flushInterval
        self.buffer = TrajectoryBuffer(maxPerRequest: maxPerRequest) { [weak self] batch in
            await self?.sendPositions(batch) ?? false
        }
    }

    // MARK: - 라이프사이클 (도식 1~5)

    /// 초기화(앱 시작 시 1회) — 키 검증 + buildings 프리페치.
    /// 통과 = "세션 가능" 확정. 실패 사유는 throw (invalidKey/positioningDisabled/network).
    func prepare() async throws {
        guard !isPrepared else { return }                            // 멱등

        // ③ 키 검증 + 클라 등록 (consent는 아직 모름 → 생략, 서버 기존값 보존)
        let verified = try await api.verify(makeVerifyRequest(consent: nil))
        guard verified.valid, verified.positioning_enabled else {
            throw SdkError.positioningDisabled
        }
        log(SdkLocalized.format("coord.verifyPass", verified.tenant_code ?? "?"))

        // ④ 빌딩·층 목록 프리페치 (경량, 1회)
        buildingsCache = try await api.buildings()
        log(SdkLocalized.format("coord.buildingsLoaded", buildingsCache?.buildings.count ?? 0))
        isPrepared = true

        // 층 자동 해석 — initialize 만으로 측위 준비가 끝나게 (start 는 바로 가동).
        // 실패해도 prepare 는 성공 — 앱이 buildings()/loadFloor() 로 수동 선택하면 된다.
        await autoSelectFloorIfNeeded()
    }

    /// 층 자동 해석 — 현재는 "첫 건물 · 도면 있는 첫 층" (단일 현장 가정).
    /// 지오펜스(가까운 건물)·BLE(층 판별)가 들어오면 정확히 이 지점이 똑똑해진다.
    private func autoSelectFloorIfNeeded() async {
        guard currentInfra == nil, !hostDidSelectFloor, let geospace else { return }
        do {
            guard let b = try await geospace.loadBuildings().first,
                  let f = b.floors.first(where: { $0.hasPlan }) ?? b.floors.first else { return }
            // 목록을 받아오는 동안 호스트가 loadFloor 를 호출했을 수 있다 — 그러면 물러난다.
            // (08-11 실기기: 앱이 DNP 를 고르는 중에 자동 선택이 607호로 덮어써 앵커 0개 수신.
            //  완료 여부(currentInfra)가 아니라 호출 여부로 판정해야 동시 진행 경합이 잡힌다)
            guard currentInfra == nil, !hostDidSelectFloor else { return }
            _ = try await performLoadFloor(buildingId: b.id, floorId: f.id)
            log(SdkLocalized.format("coord.autoSelect", b.name, f.name))
        } catch {
            log(SdkLocalized.format("coord.autoSelectFail", "\(error)"))
        }
    }

    /// 빌딩/층 트리 — 선택 UI용. geospaceKey 없으면 빈 배열 (측위 미사용 통합)
    func buildings() async throws -> [SpaceBuilding] {
        guard let geospace else { return [] }
        return try await geospace.loadBuildings()
    }

    /// 층 인프라 로드 — 도면(렌더용 반환) + 앵커·세션·존(측위·판정용 보관).
    /// start 전에 부르면 start 가 주입하고, 가동 중에 부르면 즉시 갈아끼운다(층 전환).
    @discardableResult
    func loadFloor(buildingId: String, floorId: String) async throws -> FloorInfra {
        hostDidSelectFloor = true                    // 자동 선택보다 호스트 선택이 항상 우선
        return try await performLoadFloor(buildingId: buildingId, floorId: floorId)
    }

    /// 실제 로드 — 자동 선택도 이 경로를 쓴다(표식은 세우지 않음).
    @discardableResult
    private func performLoadFloor(buildingId: String, floorId: String) async throws -> FloorInfra {
        guard let geospace else { throw SdkError.notInitialized }
        let infra = try await geospace.loadInfra(buildingId: buildingId, floorId: floorId)
        currentInfra = infra
        log(SdkLocalized.format("coord.floorLoaded", infra.anchors.count, String(floorId.prefix(8))))
        if isRunning { applyInfraToProvider() }      // 가동 중 층 전환
        return infra
    }

    /// 존만 재조회 (도면 재다운로드 없음 — 폴링용). 받은 존은 엔진에도 즉시 반영.
    /// 실패하면 지금 존을 그대로 돌려준다 — 통신 오류로 지도의 존이 사라지면 안 된다.
    /// 로그는 "결과가 바뀔 때만" — 등록 감시가 1초마다 부르는 경로라 매번 찍으면 로그창이 덮인다.
    func refreshZones() async -> [Zone] {
        guard let geospace, let infra = currentInfra else {
            logZoneOutcome(SdkLocalized.text("zone.refreshSkipped"), key: "no-floor")
            return currentInfra?.zones ?? []
        }
        do {
            let zones = try await geospace.loadZones(buildingId: infra.buildingId,
                                                     floorId: infra.floorId)
            currentInfra?.zones = zones
            if isRunning, !zones.isEmpty {
                provider?.apply(config: PositioningConfig(zones: zones))
            }
            let names = zones.map(\.name).joined(separator: ", ")
            logZoneOutcome(zones.isEmpty ? SdkLocalized.text("zone.refreshEmpty")
                                         : SdkLocalized.format("zone.refreshOk", zones.count, names),
                           key: "ok:\(names)")
            return zones
        } catch {
            logZoneOutcome(SdkLocalized.format("zone.refreshFail", infra.zones.count, "\(error)"),
                           key: "err:\(error)")
            return infra.zones
        }
    }

    /// 직전과 결과가 같으면 침묵 (폴링 도배 방지). 호스트가 버튼으로 부른 건 앱이 따로 남긴다.
    private var lastZoneOutcome: String?
    private func logZoneOutcome(_ message: String, key: String) {
        guard lastZoneOutcome != key else { return }
        lastZoneOutcome = key
        log(message)
    }

    /// currentInfra → provider (앵커·세션·존 + 건물·층 ID)
    private func applyInfraToProvider() {
        guard let infra = currentInfra, let provider else { return }
        provider.apply(buildingId: infra.buildingId, floorId: infra.floorId)
        var anchorMap: [Int: SIMD3<Double>] = [:]
        for a in infra.anchors { anchorMap[a.address] = SIMD3(a.x, a.y, a.z) }
        provider.apply(config: PositioningConfig(anchors: anchorMap,
                                                 sessionId: infra.sessionId,
                                                 zones: infra.zones))
    }

    /// 시작(매장 진입 시) — 동의 게이트 + consent 기록 + 측위 가동.
    /// prepare가 미리 끝나 있어 서버 왕복은 consent 기록 1회뿐 (buildings 재요청 없음).
    func start(consent: Bool, provider: PositioningProvider) async throws {
        guard !isRunning else { return }                             // 멱등
        guard isPrepared else { throw SdkError.notInitialized }
        guard consent else { throw SdkError.consentRequired }        // 동의 게이팅 — 수집 미시작

        // consent 기록 (verify 재호출 — "보낸 필드만 갱신" 규칙. 키 폐기도 이때 재확인됨)
        _ = try await api.verify(makeVerifyRequest(consent: consent))
        log(SdkLocalized.text("coord.consent"))

        if currentInfra == nil { await autoSelectFloorIfNeeded() }   // 재시도 안전망

        // 인프라 주입 — loadFloor 로 받아둔 층(앵커·세션·존)이 있으면 그걸로,
        // 없으면 구버전 폴백(콘솔 첫 건물·첫 층 ID만 — 앵커는 호스트 apply 의존)
        self.provider = provider
        if currentInfra != nil {
            applyInfraToProvider()
        } else if let building = buildingsCache?.buildings.first,
                  let floor = building.floors?.first {
            provider.apply(buildingId: building.building_id, floorId: floor.floor_id)
        }

        // 방문 시작
        visitorId = identity.newVisitorId()
        provider.delegate = self
        provider.start()
        isRunning = true
        startFlushTimer()
        observeAppLifecycle()
    }

    /// (선택) 고객사 회원 연결 — verify 재호출 (보낸 필드만 갱신되는 서버 규칙 활용)
    func identify(customerId: String?) {
        Task {
            var client = baseClientInfo()
            client.customer_id = customerId
            _ = try? await api.verify(ReqVerify(platform_name: "iOS",
                                                app_id: Self.appId, client: client))
        }
    }

    /// 종료: 측위 정지 + 잔여 좌표 flush (도식 11)
    func stop() async {
        guard isRunning else { return }
        provider?.stop()
        flushTimer?.invalidate(); flushTimer = nil
        removeLifecycleObservers()
        let pending = buffer.count
        log(SdkLocalized.format("coord.stopFlush", pending))
        await buffer.flush()
        if buffer.count > 0 { log(SdkLocalized.format("coord.pendingLost", buffer.count)) }
        isRunning = false
    }

    // MARK: - 전송

    /// 좌표 벌크 전송 (buffer의 Sender) — true = 200
    private func sendPositions(_ batch: [PositionPoint]) async -> Bool {
        let req = ReqPositionBulk(anon_user_id: identity.anonUserId,
                                  visitor_id: visitorId,
                                  platform_name: "iOS",
                                  points: batch)
        do {
            let res = try await api.sendPositionLogs(req)
            log(SdkLocalized.format("coord.logsSent", batch.count, res.accepted_count))
            return true
        } catch {
            log(SdkLocalized.format("coord.logsFail", batch.count))
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

    private func baseClientInfo() -> ClientInfo {
        var c = ClientInfo(anon_user_id: identity.anonUserId)
        c.sdk_version = OneS1ght.sdkVersion
        #if canImport(UIKit)
        c.os_name = "iOS"
        c.os_version = UIDevice.current.systemVersion
        #endif
        return c
    }

    private func makeVerifyRequest(consent: Bool?) -> ReqVerify {
        var client = baseClientInfo()
        client.consent = consent                              // nil이면 필드 생략 → 서버 기존값 보존
        if consent == true { client.consent_at = Self.iso(Date()) }
        return ReqVerify(platform_name: "iOS", app_id: Self.appId, client: client)
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

    /// 입장 트리거 — 빌딩 목록 캐시 보정 (start에서 이미 로드, 실패했었다면 재시도)
    func provider(_ p: PositioningProvider, didEnter buildingId: String) {
        if buildingsCache == nil {
            Task { buildingsCache = try? await api.buildings() }
        }
    }

    /// 좌표 fix — 층 설정 확보 + 버퍼 적재, 임계 도달 시 flush
    func provider(_ p: PositioningProvider, didUpdate coordinates: Coordinates,
                  floorId: String, at capturedAt: Date) {
        onPosition?(coordinates)
        ensureFloorLoaded(floorId)
        buffer.add(PositionPoint(floor_id: floorId,
                                 coordinates: coordinates,
                                 captured_at: Self.iso(capturedAt)))
        if buffer.count >= flushThreshold {
            Task { await buffer.flush() }
        }
    }

    /// 존 판정 — 즉시 전송 (network 실패만 1회 재시도), triggers는 호스트 콜백으로
    func provider(_ p: PositioningProvider, didDetectZone zoneId: String,
                  status: ZoneEventStatus, floorId: String, at occurredAt: Date) {
        ensureFloorLoaded(floorId)
        let req = ReqZoneEvent(anon_user_id: identity.anonUserId,
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
                }
            } catch {
                log(SdkLocalized.format("coord.zoneDropErr", status.rawValue))   // 서버 500이면 여기 찍힘
            }
        }
    }
}
