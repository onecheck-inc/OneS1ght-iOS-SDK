//
//  IHubPositioningProvider.swift
//  실측위 어댑터 (내장) — Geoplan 턴키 gpi-ihub
//
//  UwbPositioningProvider(NISession + gpi-dltdoa + PRM)의 후신이다. 역할 분담이 바뀐다:
//    · ihub     — BLE 로 층을 고르고, 자기 서버에서 앵커·셀을 받아 NISession 을 돌리고,
//                 좌표와 영역 진출입(IN/OUT)까지 준다.
//    · OneS1ght — 좌표를 서버에 수집하고(delegate.didUpdate), 영역 이벤트를 콘솔 zone_id 로
//                 옮겨 /events/zone → 시책(쿠폰)까지 기존 경로 그대로 태운다.
//
//  ⚠️ iOS 27+ 실기기(U1 이상) 전용. `#if os(iOS)` 가드라 맥(swift test)에서는 이 파일이
//     통째로 비워져 코어 테스트가 그대로 돈다.
//     `@available(iOS 27.0, *)` 는 패키지 최소 버전이 27 인 지금은 형식적이지만,
//     Geoplan 이 ihub 배포 타깃을 낮춰 주면 그때 곧바로 의미를 갖는다 — 지우지 말 것.
//
//  진단 한계 (종전 대비 후퇴 — 인지하고 쓸 것):
//    ihub 는 앵커 목록도, 앵커별 수신 상태도, 셀 번호도 노출하지 않는다. 그래서
//    "등록 4대 중 3대 수신 — 미수신 0x0042" 같은 특정이 불가능하다. 여기서는 콘솔
//    로케이터를 '등록' 기준으로만 쓰고, 좌표가 나오면 전부 수신으로 친다 —
//    모르는 것을 고장으로 칠하지 않는다.
//
//  층 ID: ihub 의 floorId(Int64)는 GeoSpace 층 번호이고, 콘솔 미러도 같은 값을
//  문자열("14")로 준다(2026-09-07 실측). 그래서 delegate 에는 String(floorId) 를 그대로 넘긴다.
//
//  콜백은 ihub 가 백그라운드 큐에서 부른다 — ListenerBridge 가 받아 메인으로 넘긴다.
//

#if os(iOS)

import Foundation
import Combine
import simd
import os
import CoreLocation
import gpi_ihub

// Mac 콘솔에서 필터: subsystem "co.onecheck.ones1ght" / category "IHub"
private let mlog = Logger(subsystem: "co.onecheck.ones1ght", category: "IHub")

@available(iOS 27.0, *)
@MainActor
public final class IHubPositioningProvider: NSObject, ObservableObject {

    /// ihub 자체 상태 — 측위 가동(isRunning)과는 별개다.
    /// ihub 는 층을 찾기 위해 measurement 보다 먼저 돌 수 있다.
    public enum HubPhase: String, Equatable {
        case idle, starting, searching, tracking, stopping
    }

    // MARK: - 관찰 상태 (데모/디버그 UI용)

    @Published public private(set) var isRunning = false
    @Published public private(set) var measurementCount = 0        // 누적 좌표 수 (가동 중만)
    @Published public private(set) var latestPosition: Coordinates?
    @Published public private(set) var log: [String] = []
    /// ihub 상태 — `.idle` 이 아니면 ihub 가 돌고 있다.
    @Published public private(set) var hubPhase: HubPhase = .idle
    /// ihub 가 지금 추적 중인 층 (GeoSpace 층 번호). nil = 층 탐색 중.
    @Published public private(set) var hubFloorId: Int64?

    /// 이 기기가 DL-TDoA 측위 가능한가 (칩 — OS는 @available이 보장).
    /// ⚠️ 시뮬레이터는 항상 false 다 (UWB 칩 없음).
    public static var isSupported: Bool { IntelligenceHub.isAvailableDlTdoa() }

    /// ihub 가 돌고 있는가 (탐색 중이든 추적 중이든).
    public var isDetecting: Bool { hubPhase != .idle && hubPhase != .stopping }

    // MARK: - SDK 연결 (PositioningProvider)

    public weak var delegate: PositioningProviderDelegate?

    /// 로컬 zone 이벤트 훅 (toast·쿠폰) — 서버 전송과 무관하게 호스트 UI가 즉시 반응
    public var onZoneEvent: ((ZoneEvent) -> Void)?

    /// 엔진 내부 로그 훅 — 표준 경로에서 onDebugLog 로 이어진다.
    public var onLog: ((LogLevel, String) -> Void)?

    /// ihub 전용 훅 — 층 추적 시작(id)/종료(nil), 오류. 호스트가 층 자동 선택에 쓴다.
    public var onHubFloor: ((Int64?) -> Void)?
    public var onHubError: ((_ code: Int, _ message: String) -> Void)?

    /// ihub 가 준 **원본** 영역 이벤트 — 콘솔 존으로 옮기기 전 그대로.
    /// 측위 가동 여부와 무관하게 온다. 콘솔 매핑 결과(onZoneEvent)와 나란히 놓고 보면
    /// 이름이 어긋났는지, 판정 시점이 맞는지를 현장에서 눈으로 대조할 수 있다.
    public var onHubAreaEvent: ((_ floorId: Int64, _ areaName: String,
                                 _ inOut: String, _ at: Date) -> Void)?

    /// ihub 라이선스 키. `initialize(geoSdkKey:)` 값을 FloorSession 이 넣어 준다.
    /// 비어 있으면 start 하지 않고 오류로 통지한다 (조용한 실패 금지).
    public var license = ""

    // MARK: - 내부

    private var buildingId = ""
    private var floorId = ""                          // apply(buildingId:floorId:) 로 받은 콘솔 층 ID
    /// 콘솔 로케이터 — ihub 가 앵커를 자기 서버에서 받으므로 진단 '등록' 기준으로만 쓴다.
    private var anchors: [Int: simd_double3] = [:]

    private let hub = IntelligenceHub.getInstance()
    private let bridge = ListenerBridge()
    private let judge = IHubZoneJudge()
    private let location = CLLocationManager()        // 정밀 위치 확인·임시 승격 요청 전용

    public override init() {
        super.init()
        bridge.owner = self
        judge.onEvent = { [weak self] event in
            guard let self else { return }
            self.addLog("🎯 \(event.label)")
            self.onZoneEvent?(event)
            self.forwardToSDK(event)
        }
        judge.onLog = { [weak self] level, msg in self?.addLog(level, msg) }
        addLog(SdkLocalized.format("ihub.ready", hub.getLibraryVersion(),
                                   SdkLocalized.text(Self.isSupported ? "ihub.supported"
                                                                      : "ihub.unsupported")))
    }

    /// ZoneEvent → SDK 콜백 — 서버 전송은 IN/OUT 만.
    /// DWELL 은 SDK 파생물(IN 후 타이머)이라 서버로 보내지 않고 onZoneEvent(앱 내 훅)까지만 전달.
    /// (서버 시책 매칭이 dwell 시책을 IN 에도 태우므로 같이 보내면 중복 발급 여지가 있다)
    private func forwardToSDK(_ event: ZoneEvent) {
        let fid = currentFloorIdString
        switch event {
        case .enter(let zone, let at):
            delegate?.provider(self, didDetectZone: zone.id, status: .enter, floorId: fid, at: at)
        case .exit(let zone, let at):
            delegate?.provider(self, didDetectZone: zone.id, status: .exit, floorId: fid, at: at)
        case .dwell:
            break   // 온디바이스 전용
        }
    }

    /// 서버에 실을 층 ID — ihub 가 잡은 층이 있으면 그 번호, 없으면 콘솔에서 주입받은 값.
    private var currentFloorIdString: String {
        hubFloorId.map(String.init) ?? floorId
    }

    // MARK: - 로그

    /// 외부(호스트) 로그 합류 — SDK 코어 onDebugLog 를 같은 스트림에 끼울 때 사용
    public func note(_ msg: String) { addLog(.log, msg) }
    public func note(_ level: LogLevel, _ msg: String) { addLog(level, msg) }

    private func addLog(_ msg: String) { addLog(.log, msg) }
    private func addLog(_ level: LogLevel, _ msg: String) {
        log.append(msg)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        mlog.log("\(msg, privacy: .public)")
        onLog?(level, msg)
    }

    // MARK: - 측위 통신 진단

    /// 등록 로케이터 vs 수신 — ihub 가 앵커별 상태를 주지 않아 "좌표가 나오면 전부 수신,
    /// 아니면 아직 모름" 으로만 답한다. 모르는 것을 고장으로 칠하지 않는다.
    public struct AnchorDiagnostic {
        public let registered: [Int]
        public let received: [Int]
        public let matched: [Int]
        public let missing: [Int]
        public let hasFix: Bool
        public var canPosition: Bool { hasFix }
        public let summary: String
    }

    public var diagnostic: AnchorDiagnostic {
        let reg = anchors.keys.sorted()
        let fix = latestPosition != nil
        let summary = SdkLocalized.format("ihub.diag", hubPhase.rawValue,
                                          hubFloorId.map(String.init) ?? "-",
                                          measurementCount, reg.count)
        return AnchorDiagnostic(registered: reg,
                                received: fix ? reg : [],
                                matched: fix ? reg : [],
                                missing: [],            // ihub 는 미수신을 특정할 수 없다
                                hasFix: fix,
                                summary: summary)
    }

    /// 프로토콜용 진단 — 코어(SessionCoordinator)가 읽어 로그 코드로 남긴다.
    public var positioningDiagnostic: PositioningDiagnostic? {
        let d = diagnostic
        return PositioningDiagnostic(registeredCount: d.registered.count,
                                     receivedCount: d.received.count,
                                     matchedCount: d.matched.count,
                                     missingAddresses: d.missing,
                                     hasFix: d.hasFix)
    }

    // MARK: - HubListener 이벤트 (브리지가 메인으로 넘긴 뒤)

    fileprivate func hubStarted() {
        hubPhase = .searching
        addLog(.info, SdkLocalized.text("ihub.started"))
    }

    fileprivate func hubStopped() {
        let selfStopped = hubPhase != .stopping     // stopDetection() 을 부르지 않았는데 멈춤
        hubPhase = .idle
        hub.setListener(nil)                        // README: stop() 직후가 아니라 여기서 해제
        if isRunning {
            isRunning = false
            latestPosition = nil
        }
        // 에러 3·7·10 뒤의 자동 정지 — 자동 재개 없음. 호스트가 "다시 시작" 을 안내한다.
        addLog(selfStopped ? .warn : .log,
               SdkLocalized.text(selfStopped ? "ihub.stoppedSelf" : "ihub.stopped"))
        if hubFloorId != nil {
            hubFloorId = nil
            onHubFloor?(nil)
        }
    }

    fileprivate func trackingStarted(_ fid: Int64) {
        hubPhase = .tracking
        hubFloorId = fid
        addLog(.info, SdkLocalized.format("ihub.trackingStart", fid))
        onHubFloor?(fid)
    }

    fileprivate func trackingStopped(_ fid: Int64) {
        if hubPhase == .tracking { hubPhase = .searching }
        hubFloorId = nil
        latestPosition = nil
        addLog(.info, SdkLocalized.format("ihub.trackingStop", fid))
        onHubFloor?(nil)
    }

    fileprivate func positioned(_ fid: Int64, _ x: Double, _ y: Double, _ z: Double) {
        // 탐색만 하는 동안(측위 시작 전)의 좌표는 버린다 — 화면에도, 서버에도, 판정에도 안 간다.
        guard isRunning else { return }
        let coord = Coordinates(x: x, y: y, z: z)
        latestPosition = coord
        measurementCount += 1
        // 좌표 라인은 로그에서 제외 — 초당 여러 건이라 판정 이벤트를 묻어버린다.
        // ① SDK 로 좌표 전달 (버퍼링 → positioning/logs 는 코어 몫)
        delegate?.provider(self, didUpdate: coord, floorId: String(fid), at: Date())
        // ② 존 판정은 ihub 가 한다 — 여기서 좌표를 넣지 않는다 (areaEvent 로 들어온다)
    }

    fileprivate func areaEvent(_ fid: Int64, _ name: String, _ inOut: String) {
        let now = Date()
        addLog(.info, SdkLocalized.format("ihub.area", inOut, name, fid))
        onHubAreaEvent?(fid, name, inOut, now)      // 원본 그대로 — 진단용
        // 가동 중이 아니면 여기서 끝. 수집·전송은 측위 세션 안에서만 한다.
        guard isRunning else { return }
        judge.handleAreaEvent(inOut: inOut, areaName: name, at: now)
    }

    fileprivate func errored(_ code: Int, _ msg: String) {
        addLog(.error, SdkLocalized.format("ihub.error", code, msg, Self.describe(code)))
        onHubError?(code, msg)
        // 시작 자체가 안 된 경우(1·9·11·12)는 onStopped 가 오지 않는다 — 여기서 되돌린다.
        // 3·7·10 은 구동 중이면 ihub 가 스스로 멈추고 onStopped 가 뒤따른다(hubStopped 에서 처리).
        if hubPhase == .starting, [1, 9, 11, 12].contains(code) {
            hubPhase = .idle
            if isRunning { isRunning = false; latestPosition = nil }
            hub.setListener(nil)
        }
    }

    /// gpi-ihub README §5 에러 코드 표
    private static func describe(_ code: Int) -> String {
        (1...12).contains(code) ? SdkLocalized.text("ihub.err\(code)")
                                : SdkLocalized.text("ihub.errUnknown")
    }

    // MARK: - ihub 기동 (측위 시작과 분리)

    /// ihub 를 띄워 층부터 찾는다. 좌표는 아직 쓰지 않는다 — 층이 잡히면 `onHubFloor` 로
    /// 알리고, 호스트가 건물·층을 자동 선택한다. 측위 가동은 그 뒤 `start()` 가 한다.
    public func startDetection() {
        guard hubPhase == .idle else { return }
        let key = license.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            addLog(.error, SdkLocalized.text("ihub.noLicense"))
            onHubError?(1, "license not set")
            return
        }
        IntelligenceHub.setLicense(key)
        hubFloorId = nil
        hubPhase = .starting
        addLog(.info, SdkLocalized.format("ihub.starting", String(key.prefix(8))))

        // ihub 는 정밀 위치가 필수다(에러 7). 대략 위치면 임시 승격을 먼저 요청한다.
        if location.accuracyAuthorization != .fullAccuracy {
            addLog(.warn, SdkLocalized.text("ihub.fullAccuracy"))
            location.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "Positioning") { [weak self] _ in
                Task { @MainActor in self?.launchHub() }
            }
        } else {
            launchHub()
        }
    }

    private func launchHub() {
        guard hubPhase == .starting else { return }   // 그 사이 정지됐으면 무시
        hub.setListener(bridge)
        hub.start()
    }

    /// ihub 를 완전히 멈춘다. 측위 중이었으면 그것도 끝난다.
    public func stopDetection() {
        guard hubPhase != .idle, hubPhase != .stopping else { return }
        hubPhase = .stopping
        if isRunning {
            isRunning = false
            latestPosition = nil
        }
        hub.stop()                                   // 정리가 끝나면 onStopped 가 온다
        addLog(.info, SdkLocalized.format("ihub.stopRequested", measurementCount))
    }
}

// MARK: - PositioningProvider (SDK 코어가 start/stop 을 부른다)

@available(iOS 27.0, *)
extension IHubPositioningProvider: PositioningProvider {

    /// 콘솔 건물·층 ID — 코어(applyFloorStateToProvider)가 넣는다.
    public func apply(buildingId: String, floorId: String) {
        self.buildingId = buildingId
        self.floorId = floorId
        addLog(SdkLocalized.format("provider.configApply", String(floorId.prefix(8))))
    }

    /// 콘솔 로케이터·세션·존.
    /// · 앵커·세션은 ihub 가 자기 서버에서 받으므로 **주입해도 측위에 쓰이지 않는다** — 진단용.
    /// · 존은 zone_id 매핑용으로 판정기에 꽂는다. 빈 목록도 "없다"는 뜻이라 그대로 반영한다
    ///   (구역을 전부 지운 상황이 엔진에 전달되지 않으면 사라진 구역에서 시책이 계속 발화한다).
    public func apply(config: PositioningConfig) {
        if !config.anchors.isEmpty { anchors = config.anchors }
        judge.apply(zones: config.zones)
        addLog(SdkLocalized.format("ihub.zonesApply", config.zones.count, config.anchors.count))
    }

    // positioningDiagnostic 은 클래스 본문에 있다 (프로토콜 요구사항을 그쪽이 충족한다).

    /// 측위 가동 — 코어가 `begin(provider:)` 에서 부른다.
    /// ihub 가 아직 안 돌고 있으면 여기서 띄운다.
    public func start() {
        guard !isRunning else { return }
        if hubPhase == .idle { startDetection() }
        guard hubPhase != .idle else { return }     // 라이선스 없음 등으로 못 뜬 경우
        measurementCount = 0
        latestPosition = nil
        judge.reset()
        isRunning = true
        addLog(.info, SdkLocalized.format("ihub.positioningOn",
                                          hubFloorId.map(String.init) ?? "-"))
        // 입장 트리거 — SDK 가 buildings/floors 로드를 시작하게
        delegate?.provider(self, didEnter: buildingId)
    }

    /// 측위 종료 — 좌표 표시·수집·판정을 끄고 ihub 도 함께 멈춘다.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        latestPosition = nil
        addLog(.info, SdkLocalized.format("ihub.positioningOff", measurementCount))
        stopDetection()
    }
}

// MARK: - 브리지 (ihub 백그라운드 큐 → 메인)

@available(iOS 27.0, *)
private final class ListenerBridge: HubListener {
    weak var owner: IHubPositioningProvider?

    private func onMain(_ body: @escaping @MainActor (IHubPositioningProvider) -> Void) {
        Task { @MainActor [weak owner] in
            if let owner { body(owner) }
        }
    }

    func onStarted() { onMain { $0.hubStarted() } }
    func onStopped() { onMain { $0.hubStopped() } }
    func onTrackingStarted(_ floorId: Int64) { onMain { $0.trackingStarted(floorId) } }
    func onTrackingStopped(_ floorId: Int64) { onMain { $0.trackingStopped(floorId) } }
    func onPosition(_ floorId: Int64, _ x: Double, _ y: Double, _ z: Double) {
        onMain { $0.positioned(floorId, x, y, z) }
    }
    func onAreaEvent(_ floorId: Int64, _ areaName: String, _ inOut: String) {
        onMain { $0.areaEvent(floorId, areaName, inOut) }
    }
    func onError(_ code: Int, _ msg: String) { onMain { $0.errored(code, msg) } }
}

#endif  // os(iOS)
