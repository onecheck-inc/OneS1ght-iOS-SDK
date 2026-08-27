//
//  UwbPositioningProvider.swift
//  실측위 어댑터 (내장) — NISession + gpi-dltdoa + ZoneEngine
//
//  UWB 전파 수신 → 좌표 계산 → 존 판정까지 하고, 결과를 PositioningProvider
//  콜백 3종(didEnter/didUpdate/didDetectZone)으로 SDK 코어에 흘려보낸다.
//
//  ⚠️ iOS 27+ 실기기(U1) 전용 — 컴파일에 iOS 27 SDK(현재 Xcode 27 베타) 필요.
//     #if os(iOS) 가드라 맥(swift test)에서는 이 파일이 통째로 비워진다.
//  ⚠️ 앵커·Zone은 금정역 skv1 607호 실측값 하드코딩 — 서버 floors polygon이
//     픽셀(×57.7)로 내려오는 버그가 풀리면 config 기반으로 교체.
//

#if os(iOS)

import Foundation
import Combine
import simd
import os
import NearbyInteraction
import gpi_dltdoa

// Mac 콘솔에서 필터: subsystem "co.onecheck.ones1ght" / category "UWB"
private let mlog = Logger(subsystem: "co.onecheck.ones1ght", category: "UWB")

@available(iOS 27.0, *)
@MainActor
public final class UwbPositioningProvider: NSObject, ObservableObject {

    // MARK: - 관찰 상태 (데모/디버그 UI용)

    @Published public private(set) var isRunning = false
    @Published public private(set) var measurementCount = 0        // 누적 measurement (앵커 신호 지표)
    @Published public private(set) var latestPosition: Coordinates?

    /// 디버그 로그 (판단 1초 로그 포함 — 데모 앱 표시용)
    @Published public private(set) var log: [String] = []

    /// 이 기기가 DL-TDoA 측위 가능한가 (칩 — OS는 @available이 보장)
    public static var isSupported: Bool {
        NISession.deviceCapabilities.supportsDLTDOAMeasurement
    }

    // MARK: - SDK 연결 (PositioningProvider)

    public weak var delegate: PositioningProviderDelegate?

    /// 로컬 zone 이벤트 훅 (toast·쿠폰) — 서버 전송과 무관하게 호스트 UI가 즉시 반응
    public var onZoneEvent: ((ZoneEvent) -> Void)?

    /// 엔진 내부 로그 훅 — 표준 경로(start(consent:))에서 onDebugLog 로 이어진다.
    /// "세션 N으로 추적 시작 / 수신 대기 / 세션 오류" 가 앱에 보여야 무수신을 진단할 수 있다.
    public var onLog: ((String) -> Void)?

    // MARK: - 인프라 설정 (전부 주입 — 하드코딩 없음)
    //
    // buildingId/floorId  → SDK 코어가 buildings API 값으로 apply(buildingId:floorId:) 주입
    // anchors·sessionId   → 호스트가 apply(config:) 로 주입 (소스: GeoSpace 또는 console 프록시)
    // zones               → 서버 config 경로 열리면 주입 예정 (아래 zoneEngine 참조)

    private var buildingId = ""
    private var floorId = ""
    private var networkIdentifier: Int?    // 층별 UWB 세션 — apply(config:)의 sessionId로 주입 (미주입 시 start 거부)

    /// 앵커 좌표 (짧은주소 → 도면 로컬 미터) — apply(config:) 주입값. 진단(diagnostic)의 '등록' 기준.
    private var anchors: [Int: simd_double3] = [:]

    /// 좌표 → Zone 판정 엔진 — Geoplan PRM (콘솔 존 파라미터를 실제로 소비).
    /// 존은 apply(config:) 로 주입된다 (층 전환 시 stop→start 교체).
    public let zoneEngine: any ZoneJudging = PrmZoneEngine()

    // MARK: - 내부

    private var session: NISession?
    private let positioner = DLTDoAPositioner(minRssi: -90.0)
    private var cancellable: AnyCancellable?
    // TODO(진단·★다음 주 필수): 앵커 수신 진단 — start 후 N초에 anchors(등록) vs seenAddresses(수신)
    //   차집합을 onDebugLog로 리포트 ("등록 4대 중 3대 수신 — 미수신: 00042").
    //   로케이터 다운 시 "좌표가 그냥 안 나옴"의 유일한 온디바이스 원인 특정 수단.
    //   상세: issues/discussion-points-2026-07.md 하단 SDK TODO.
    private var seenAddresses = Set<UInt64>()

    public override init() {
        super.init()
        addLog(SdkLocalized.format("provider.ready", DLTDoAPositioner.sdkVersion))

        // Zone 이벤트 확정 시: ① 로그 ② 로컬 UI 훅 ③ SDK delegate(서버 전송)
        zoneEngine.onEvent = { [weak self] event in
            guard let self else { return }
            self.addLog("🎯 \(event.label)")
            self.onZoneEvent?(event)
            self.forwardToSDK(event)
        }
        // PRM 수명주기·오류 진단 (조용한 실패 금지)
        (zoneEngine as? PrmZoneEngine)?.onLog = { [weak self] msg in self?.addLog(msg) }
        // 1초 판단 로그 (디바운스 튜닝용)
        zoneEngine.onJudge = { [weak self] j in
            let inside = j.insideZone.map { SdkLocalized.format("provider.judgeInside", $0) }
                ?? SdkLocalized.text("provider.judgeOutside")
            self?.addLog(String(format: "⏱ (%.1f,%.1f) %@ in%d out%d [%@]",
                                j.position.x, j.position.y, inside,
                                j.inStreak, j.outStreak, j.activeZone ?? "OUT"))
        }
        addLog(SdkLocalized.text("provider.zoneReady"))
    }

    /// ZoneEngine 이벤트 → SDK 콜백 — 서버 전송은 PRM 판정(IN/OUT)만.
    /// DWELL 은 SDK 파생물(IN 후 타이머)이라 서버로 보내지 않고 onZoneEvent(앱 내 훅)까지만 전달.
    /// · 서버 시책 매칭이 dwell 시책을 IN 에도 태우므로, DWELL 을 같이 보내면 중복 발급 여지가 있음
    /// · 체류 시간은 서버가 IN~OUT 시간차로 산출
    private func forwardToSDK(_ event: ZoneEvent) {
        switch event {
        case .enter(let zone, let at):
            delegate?.provider(self, didDetectZone: zone.id, status: .enter,
                               floorId: floorId, at: at)
        case .exit(let zone, let at):
            delegate?.provider(self, didDetectZone: zone.id, status: .exit,
                               floorId: floorId, at: at)
        case .dwell:
            break   // 온디바이스 전용 — onZoneEvent 로만 나감
        }
    }

    // MARK: - 로그

    /// 외부(호스트) 로그 합류 — SDK 코어 onDebugLog를 같은 로그 스트림에 끼울 때 사용
    public func note(_ msg: String) { addLog(msg) }

    /// ★ 측위 설정 주입 (공개 계약) — SDK 코어가 받아온 앵커·세션·존을 여기로 꽂는다.
    /// 소스가 콘솔이든 GeoSpace든 이 통로는 고정. start 전에 호출.
    public func apply(config: PositioningConfig) {
        applyAnchors(config.anchors)
        if let sid = config.sessionId { applySessionId(sid) }
        // **빈 목록도 그대로 넘긴다.** 예전엔 `if !config.zones.isEmpty` 로 걸러서, 구역을
        // 전부 지운 상황이 엔진에 영영 전달되지 않았다 — SessionCoordinator.refreshZones()
        // 가 바로 그걸 하려고 빈 목록을 보내는데(주석에 이유까지 적혀 있다) 여기서 조용히
        // 버려져, 판정 엔진이 삭제된 구역을 계속 물고 지도에서 사라진 자리에서 없어진
        // 시책이 계속 발화했다.
        //
        // 지금 호출부는 넷 다 "이 층의 구역은 이것이 전부다" 라는 뜻으로 부른다
        // (층 해제 · 구역 새로고침 · 층 상태 주입 · 앱의 층 선택). 빈 목록은 "건드리지
        // 말라" 가 아니라 "없다" 이므로, 그대로 반영하는 것이 맞다.
        zoneEngine.apply(zones: config.zones)
        addLog(SdkLocalized.format("coord.zonesApply", config.zones.count))
    }

    /// 외부(GeoSpace)에서 받은 앵커 좌표로 교체 (apply(config:) 내부에서 사용).
    private func applyAnchors(_ coords: [Int: simd_double3]) {
        guard !coords.isEmpty else { return }
        anchors = coords                                  // 진단 '등록' 기준도 함께 갱신
        positioner.anchorCoordinatesOverride = coords
        addLog(SdkLocalized.format("provider.anchorsApply", coords.count))
    }

    /// 층별 UWB 세션(networkIdentifier) 주입 (apply(config:) 내부에서 사용).
    private func applySessionId(_ id: Int) {
        networkIdentifier = id
        addLog(SdkLocalized.format("provider.sessionApply", id))
    }

    // MARK: - 측위 통신 진단 ("여기서 측위 되나?")

    /// 등록 앵커 vs 실제 수신 앵커 비교 결과.
    public struct AnchorDiagnostic {
        public let registered: [Int]   // 등록(override)된 앵커 주소
        public let received: [Int]     // 실제 레인징으로 잡힌 주소
        public let matched: [Int]      // 등록 ∩ 수신 (좌표 있는 유효 앵커)
        public let missing: [Int]      // 등록됐는데 미수신 (로케이터 다운 의심)
        public let hasFix: Bool        // geoSDK가 좌표를 실제 산출 중
        /// 2D DL-TDoA 최소 3대(유효 앵커) 필요
        public var canPosition: Bool { hasFix || matched.count >= 3 }
        public var summary: String {
            let miss = missing.map { String(format: "0x%04X", $0) }.joined(separator: ",")
            let verdict = hasFix ? SdkLocalized.text("diag.ok")
                        : matched.count >= 3 ? SdkLocalized.text("diag.pending")
                        : SdkLocalized.format("diag.fail", matched.count)
            let missPart = missing.isEmpty ? "" : SdkLocalized.format("diag.missing", miss)
            return SdkLocalized.format("diag.summary", registered.count, received.count, matched.count, missPart, verdict)
        }
    }

    /// 프로토콜용 진단 — 코어(SessionCoordinator)가 이 값을 읽어 로그 코드로 남긴다.
    /// AnchorDiagnostic 을 그대로 노출하지 않는 이유는 코어가 iOS 전용 타입을 몰라야 하기 때문이다.
    public var positioningDiagnostic: PositioningDiagnostic? {
        let d = diagnostic
        return PositioningDiagnostic(
            registeredCount: d.registered.count,
            receivedCount: d.received.count,
            matchedCount: d.matched.count,
            missingAddresses: d.missing,
            hasFix: d.hasFix)
    }

    /// 현재 시점 측위 통신 진단 (트래킹 중 누적 수신 기준 — 세션 켜져 있어야 의미 있음).
    public var diagnostic: AnchorDiagnostic {
        let reg = Set(anchors.keys)
        let recv = Set(seenAddresses.map { Int($0) })
        return AnchorDiagnostic(
            registered: reg.sorted(),
            received: recv.sorted(),
            matched: reg.intersection(recv).sorted(),
            missing: reg.subtracting(recv).sorted(),
            hasFix: latestPosition != nil
        )
    }

    private func addLog(_ msg: String) {
        log.append(msg)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        mlog.log("\(msg, privacy: .public)")
        onLog?(msg)
    }
}

// MARK: - PositioningProvider (SDK 코어가 start/stop을 부른다)

@available(iOS 27.0, *)
extension UwbPositioningProvider: PositioningProvider {

    /// 서버 config 반영 — buildings API의 건물·층 UUID로 교체 (start 전에 코어가 호출)
    public func apply(buildingId: String, floorId: String) {
        self.buildingId = buildingId
        self.floorId = floorId
        addLog(SdkLocalized.format("provider.configApply", String(floorId.prefix(8))))
    }

    public func start() {
        guard !isRunning else { return }
        // 세션ID 미주입 = 측위 불가 (apply(config:) 먼저) — 하드코딩 폴백 없음
        guard let networkIdentifier else {
            addLog(SdkLocalized.text("provider.noSession"))
            return
        }

        measurementCount = 0
        latestPosition = nil
        seenAddresses.removeAll()
        zoneEngine.reset()
        isRunning = true
        addLog(SdkLocalized.format("provider.trackingStart", networkIdentifier))

        // 입장 트리거 — SDK가 buildings/floors 로드를 시작하게
        delegate?.provider(self, didEnter: buildingId)

        // geoSDK 좌표 스트림 구독
        // DispatchQueue.main 사용 — RunLoop.main 은 스크롤·제스처 중 배달을 멈춰
        // 좌표가 수 초씩 뭉쳤다 터지고, PRM 시간 게이트(집계간격)가 오판정(리셋)된다 (08-06 실기기 확인)
        cancellable = positioner.$estimatedPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pos in
                guard let self, let pos else { return }
                let coord = Coordinates(x: pos.x, y: pos.y, z: pos.z)
                self.latestPosition = coord
                // 좌표 라인은 로그에서 제외 — 4Hz 로 로그·증적 파일을 도배해 판정 이벤트를 묻어버림.
                // (좌표 자체는 latestPosition·서버 버퍼·PRM 주입으로 전부 살아 있음)
                // ① SDK로 좌표 전달 (버퍼링→서버는 코어 몫)
                self.delegate?.provider(self, didUpdate: coord,
                                        floorId: self.floorId, at: Date())
                // ② Zone 판정 (온디바이스)
                self.zoneEngine.ingest(Position(x: pos.x, y: pos.y), now: Date())
            }

        // NISession 가동 (DL-TDoA 모드)
        let session = NISession()
        session.delegate = self
        self.session = session
        session.run(NIDLTDOAConfiguration(networkIdentifier: networkIdentifier))
        addLog(SdkLocalized.text("provider.waiting"))

        // 통신 진단 — 5초 뒤 1회 자동 리포트 (측위 가능 여부)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.isRunning else { return }
            self.addLog(SdkLocalized.format("provider.diag", self.diagnostic.summary))
        }
    }

    public func stop() {
        guard isRunning else { return }
        session?.invalidate(); session = nil
        cancellable?.cancel(); cancellable = nil
        isRunning = false
        latestPosition = nil        // 빨간점 제거 (중단 = 라이브 위치 없음)
        addLog(SdkLocalized.format("provider.trackingStop", measurementCount))
    }
}

// MARK: - NISessionDelegate

@available(iOS 27.0, *)
extension UwbPositioningProvider: NISessionDelegate {

    // ★ 핵심: 앵커 DTM 수신 → geoSDK에 그대로 주입
    public nonisolated func session(_ session: NISession,
                                    didUpdateDLTDOA measurements: [NIDLTDOAMeasurement]) {
        Task { @MainActor in
            self.measurementCount += measurements.count
            self.positioner.update(measurements: measurements)
            // 새로 잡힌 앵커만 1회 로깅 (override 매칭 확인)
            for m in measurements {
                let addr = UInt64(m.address)
                if self.seenAddresses.insert(addr).inserted {
                    let matched = SdkLocalized.text(self.anchors[Int(addr)] != nil
                                                ? "provider.anchorMatched" : "provider.anchorUnmatched")
                    self.addLog(String(format: SdkLocalized.text("provider.anchorScan"),
                                       addr, m.signalStrength, matched))
                }
            }
        }
    }

    public nonisolated func sessionWasSuspended(_ session: NISession) {
        Task { @MainActor in self.addLog(SdkLocalized.text("provider.suspended")) }
    }

    /// 중단이 끝났다 — **여기서 같은 설정으로 run 을 다시 불러야 측정이 재개된다.**
    ///
    /// NearbyInteraction 은 중단이 풀렸다고 알아서 다시 재지 않는다. 이 델리게이트가
    /// 오는 것 자체가 "이제 다시 run 해도 된다"는 신호이고, 재실행은 앱 몫이다
    /// (Apple NISessionDelegate 계약). 이걸 빼먹으면 좌표가 그 자리에서 영영 멈춘다 —
    /// 오류도 로그도 없고 isRunning 은 참이라, 화면상으로는 "측위 중"인데 점만 안 움직인다.
    /// 중단은 앱이 백그라운드로 갔다 오는 것만으로도 일어나므로 증상이 간헐적으로 보인다.
    ///
    /// 이미 stop() 된 뒤에 늦게 도착한 콜백으로 세션이 되살아나지 않도록 isRunning 을 보고,
    /// 우리가 들고 있는 세션이 맞을 때만 재실행한다(층을 갈아탄 뒤 옛 세션의 콜백 방지).
    public nonisolated func sessionSuspensionEnded(_ session: NISession) {
        Task { @MainActor in
            self.addLog(SdkLocalized.text("provider.resumed"))
            guard self.isRunning,
                  session === self.session,
                  let networkIdentifier = self.networkIdentifier else { return }
            session.run(NIDLTDOAConfiguration(networkIdentifier: networkIdentifier))
        }
    }

    public nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        // 권한 거부는 "고칠 수 있는 실패"라 일반 오류와 구분해 알린다 — 앱이 설정 안내를 띄울 수 있게.
        // permissions() 로 미리 확인했더라도 사용자가 설정에서 나중에 끌 수 있어 이 경로는 계속 필요하다.
        let denied = (error as NSError).code == NIError.Code.userDidNotAllow.rawValue
        Task { @MainActor in
            self.addLog(denied ? SdkLocalized.text("provider.permissionDenied")
                               : SdkLocalized.format("provider.invalid", error.localizedDescription))
            self.stop()
        }
    }
}

#endif  // os(iOS)
