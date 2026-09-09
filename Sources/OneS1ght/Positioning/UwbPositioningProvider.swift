//
//  UwbPositioningProvider.swift
//  실측위 어댑터 (내장) — 외부 측위 엔진
//
//  UwbPositioningProvider(직접 레인징 + 자체 존 판정)의 후신이다. 역할 분담이 바뀐다:
//    · 엔진     — BLE 로 층을 고르고, 자기 서버에서 앵커·셀을 받아 NISession 을 돌리고,
//                 좌표와 영역 진출입(IN/OUT)까지 준다.
//    · OneS1ght — 좌표를 서버에 수집하고(delegate.didUpdate), 영역 이벤트를 콘솔 zone_id 로
//                 옮겨 /events/zone → 시책(쿠폰)까지 기존 경로 그대로 태운다.
//
//  ⚠️ iOS 27+ 실기기(U1 이상) 전용. `#if os(iOS)` 가드라 맥(swift test)에서는 이 파일이
//     통째로 비워져 코어 테스트가 그대로 돈다.
//     `@available(iOS 27.0, *)` 는 패키지 최소 버전이 27 인 지금은 형식적이지만,
//     엔진 공급사가 배포 타깃을 낮춰 주면 그때 곧바로 의미를 갖는다 — 지우지 말 것.
//
//  진단 한계 (종전 대비 후퇴 — 인지하고 쓸 것):
//    엔진은 앵커 목록도, 앵커별 수신 상태도, 셀 번호도 노출하지 않는다. 그래서
//    "등록 4대 중 3대 수신 — 미수신 0x0042" 같은 특정이 불가능하다. 여기서는 콘솔
//    로케이터를 '등록' 기준으로만 쓰고, 좌표가 나오면 전부 수신으로 친다 —
//    모르는 것을 고장으로 칠하지 않는다.
//
//  층 ID: 엔진의 floorId(Int64)는 공간 서비스 층 번호이고, 콘솔 미러도 같은 값을
//  문자열("14")로 준다(2026-09-07 실측). 그래서 delegate 에는 String(floorId) 를 그대로 넘긴다.
//
//  콜백은 엔진이 백그라운드 큐에서 부른다 — ListenerBridge 가 받아 메인으로 넘긴다.
//

#if os(iOS)

import Foundation
import Combine
import simd
import os
import CoreLocation
import gpi_ihub

// Mac 콘솔에서 필터: subsystem "co.onecheck.ones1ght" / category "UWB"
private let mlog = Logger(subsystem: "co.onecheck.ones1ght", category: "UWB")

@available(iOS 27.0, *)
@MainActor
public final class UwbPositioningProvider: NSObject, ObservableObject {

    /// 엔진 자체 상태 — 측위 가동(isRunning)과는 별개다.
    /// 엔진은 층을 찾기 위해 measurement 보다 먼저 돌 수 있다.
    public enum PositioningPhase: String, Equatable {
        case idle, starting, searching, tracking, stopping
    }

    // MARK: - 관찰 상태 (데모/디버그 UI용)

    @Published public private(set) var isRunning = false
    @Published public private(set) var measurementCount = 0        // 누적 좌표 수 (가동 중만)
    @Published public private(set) var latestPosition: Coordinates?
    @Published public private(set) var log: [String] = []
    /// 엔진 상태 — `.idle` 이 아니면 엔진이 돌고 있다.
    @Published public private(set) var phase: PositioningPhase = .idle
    /// 엔진이 지금 추적 중인 층 (공간 서비스 층 번호). nil = 층 탐색 중.
    @Published public private(set) var detectedFloorId: Int64?

    /// 이 기기가 DL-TDoA 측위 가능한가 (칩 — OS는 @available이 보장).
    /// ⚠️ 시뮬레이터는 항상 false 다 (UWB 칩 없음).
    public static var isSupported: Bool { IntelligenceHub.isAvailableDlTdoa() }

    /// 엔진이 돌고 있는가 (탐색 중이든 추적 중이든).
    public var isDetecting: Bool { phase != .idle && phase != .stopping }

    // MARK: - SDK 연결 (PositioningProvider)

    public weak var delegate: PositioningProviderDelegate?

    /// 로컬 zone 이벤트 훅 (toast·쿠폰) — 서버 전송과 무관하게 호스트 UI가 즉시 반응
    public var onZoneEvent: ((ZoneEvent) -> Void)?

    /// 엔진 내부 로그 훅 — 표준 경로에서 onDebugLog 로 이어진다.
    public var onLog: ((LogLevel, String) -> Void)?

    /// 엔진 전용 훅 — 층 추적 시작(id)/종료(nil), 오류. 호스트가 층 자동 선택에 쓴다.
    public var onFloorDetected: ((Int64?) -> Void)?
    public var onEngineError: ((_ code: Int, _ message: String) -> Void)?

    /// 엔진이 준 **원본** 영역 이벤트 — 콘솔 존으로 옮기기 전 그대로.
    /// 측위 가동 여부와 무관하게 온다. 콘솔 매핑 결과(onZoneEvent)와 나란히 놓고 보면
    /// 이름이 어긋났는지, 판정 시점이 맞는지를 현장에서 눈으로 대조할 수 있다.
    public var onRawAreaEvent: ((_ floorId: Int64, _ areaName: String,
                                 _ inOut: String, _ at: Date) -> Void)?

    /// 엔진 라이선스 키. `initialize(geoSdkKey:)` 값을 FloorSession 이 넣어 준다.
    /// 비어 있으면 start 하지 않고 오류로 통지한다 (조용한 실패 금지).
    public var license = ""

    // MARK: - 내부

    private var buildingId = ""
    private var floorId = ""                          // apply(buildingId:floorId:) 로 받은 콘솔 층 ID
    /// 콘솔 로케이터 — 엔진이 앵커를 자기 서버에서 받으므로 진단 '등록' 기준으로만 쓴다.
    private var anchors: [Int: simd_double3] = [:]

    /// 층 미탐지 감시. 측위를 켰는데 이 시간이 지나도록 층이 안 잡히면 E3007 을 남긴다.
    /// 엔진은 층을 못 찾아도 오류를 주지 않고 계속 탐색만 한다 — 앱에서는 "그냥 좌표가
    /// 안 나온다"로만 보여서, 이 감시가 없으면 BLE 미수신이 아무 흔적도 남기지 않는다.
    private var floorWatchTask: Task<Void, Never>?
    static let floorDetectDelay: TimeInterval = 20

    /// 층 불일치는 한 번만 알린다 — 층이 유지되는 동안 반복하면 로그가 덮인다.
    private var warnedFloorMismatch: Int64?

    private let hub = IntelligenceHub.getInstance()
    private let bridge = ListenerBridge()
    private let judge = UwbAreaJudge()
    private let locationGate = LocationAuthGate()     // 위치 권한 확인·요청 전용

    /// `NSLocationTemporaryUsageDescriptionDictionary` 안의 키와 **글자까지 같아야** 한다.
    /// 어긋나면 승격 요청이 조용히 무시된다(오류도 로그도 없다).
    static let accuracyPurposeKey = "Positioning"

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
        judge.onReport = { [weak self] code, ctx in self?.reportToSDK(code, ctx) }
        addLog(SdkLocalized.format("uwb.ready", hub.getLibraryVersion(),
                                   SdkLocalized.text(Self.isSupported ? "uwb.supported"
                                                                      : "uwb.unsupported")))
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

    /// 서버에 실을 층 ID — 엔진이 잡은 층이 있으면 그 번호, 없으면 콘솔에서 주입받은 값.
    private var currentFloorIdString: String {
        detectedFloorId.map(String.init) ?? floorId
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

    /// 등록 로케이터 vs 수신 — 엔진이 앵커별 상태를 주지 않아 "좌표가 나오면 전부 수신,
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
        let summary = SdkLocalized.format("uwb.diag", phase.rawValue,
                                          detectedFloorId.map(String.init) ?? "-",
                                          measurementCount, reg.count)
        return AnchorDiagnostic(registered: reg,
                                received: fix ? reg : [],
                                matched: fix ? reg : [],
                                missing: [],            // 엔진은 미수신을 특정할 수 없다
                                hasFix: fix,
                                summary: summary)
    }

    /// 프로토콜용 진단 — 코어(SessionCoordinator)가 읽어 로그 코드로 남긴다.
    ///
    /// ⚠️ `canAttributePerAnchor: false` 를 반드시 실어 보낸다. 이 값을 빼면 코어의
    ///    수신 점검이 `missing.isEmpty`·`matched >= 3` 두 조건에 걸려 **영원히 아무것도
    ///    보고하지 않는다** — 좌표가 안 나오는데 로그가 한 줄도 안 남는 상태가 된다.
    public var positioningDiagnostic: PositioningDiagnostic? {
        let d = diagnostic
        return PositioningDiagnostic(registeredCount: d.registered.count,
                                     receivedCount: d.received.count,
                                     matchedCount: d.matched.count,
                                     missingAddresses: d.missing,
                                     hasFix: d.hasFix,
                                     canAttributePerAnchor: false)
    }

    // MARK: - 진단 코드 보고

    /// 엔진 고유의 실패를 SDK 표준 경로(onDebugLog + 서버 E-코드)로 올린다.
    /// 화면 로그(addLog)만으로는 콘솔 로그 분석기에 한 줄도 안 올라간다.
    private func reportToSDK(_ code: SdkErrorCode, _ context: String = "") {
        delegate?.provider(self, didReport: code, context: context)
    }

    /// 측위 엔진 오류 코드 → SDK E-코드.
    /// `nil` 은 "로그로만 남길 것" — 2(중복 start)·8(정지 중 start)은 호출 순서 문제라
    /// 현장 진단 가치가 없고, 코드로 올리면 재시도마다 쌓여 진짜 오류를 덮는다.
    /// 상태를 읽지 않는 순수 변환이라 `nonisolated` 다 — 클래스가 `@MainActor` 라는 이유로
    /// 격리에 묶이면 어느 큐에서 온 오류든 메인으로 건너와야 코드를 매길 수 있게 된다.
    nonisolated static func sdkCode(forHubError code: Int) -> SdkErrorCode? {
        switch code {
        case 1:  return .invalidKey           // 라이선스 미등록
        case 3:  return .permissionDenied     // Bluetooth 불가(꺼짐·권한·미지원)
        case 4:  return .locatorsMissing      // 그 층의 앵커 정보 없음
        case 5:  return .uwbSessionFailed     // DL-TDoA 세션 오류
        case 6:  return .areaJudgeFailed      // 영역 판정 오류
        case 7:  return .permissionDenied     // 위치 불가(권한·정밀도·서비스 꺼짐)
        case 9:  return .permissionDenied     // Info.plist BT 키 누락
        case 10: return .invalidKey           // 서버가 라이선스 거부
        case 11: return .network              // 라이선스 서버 미도달
        case 12: return .deviceNotSupported   // DL-TDoA 미지원 기기
        default: return nil                   // 2 · 8 · 미지의 코드
        }
    }

    // MARK: - HubListener 이벤트 (브리지가 메인으로 넘긴 뒤)

    fileprivate func hubStarted() {
        phase = .searching
        addLog(.info, SdkLocalized.text("uwb.started"))
    }

    fileprivate func hubStopped() {
        let selfStopped = phase != .stopping     // stopDetection() 을 부르지 않았는데 멈춤
        phase = .idle
        floorWatchTask?.cancel(); floorWatchTask = nil
        hub.setListener(nil)                        // README: stop() 직후가 아니라 여기서 해제
        if isRunning {
            isRunning = false
            latestPosition = nil
        }
        // 에러 3·7·10 뒤의 자동 정지 — 자동 재개 없음. 호스트가 "다시 시작" 을 안내한다.
        addLog(selfStopped ? .warn : .log,
               SdkLocalized.text(selfStopped ? "uwb.stoppedSelf" : "uwb.stopped"))
        if detectedFloorId != nil {
            detectedFloorId = nil
            onFloorDetected?(nil)
        }
    }

    fileprivate func trackingStarted(_ fid: Int64) {
        phase = .tracking
        detectedFloorId = fid
        floorWatchTask?.cancel(); floorWatchTask = nil      // 층을 찾았다 — 미탐지 감시 해제
        addLog(.info, SdkLocalized.format("uwb.trackingStart", fid))
        checkFloorAgreement(fid)
        onFloorDetected?(fid)
    }

    /// 엔진이 잡은 층 ↔ 콘솔이 지정한 층 대조.
    ///
    /// 서버로 나가는 `floor_id` 는 엔진 값이다(currentFloorIdString). 두 값이 어긋난 채로
    /// 두면 좌표·존 이벤트가 콘솔이 모르는 층에 쌓여, 화면에서는 "데이터가 없다"로만 보인다.
    /// 콘솔 층이 아직 안 정해졌으면(층 자동선택 전) 대조하지 않는다 — 그건 불일치가 아니다.
    private func checkFloorAgreement(_ fid: Int64) {
        guard !floorId.isEmpty, floorId != String(fid) else { return }
        guard warnedFloorMismatch != fid else { return }
        warnedFloorMismatch = fid
        reportToSDK(.floorIdMismatch, "engine=\(fid) console=\(floorId)")
    }

    fileprivate func trackingStopped(_ fid: Int64) {
        if phase == .tracking { phase = .searching }
        detectedFloorId = nil
        latestPosition = nil
        addLog(.info, SdkLocalized.format("uwb.trackingStop", fid))
        onFloorDetected?(nil)
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
        // ② 존 판정은 엔진이 한다 — 여기서 좌표를 넣지 않는다 (areaEvent 로 들어온다)
    }

    fileprivate func areaEvent(_ fid: Int64, _ name: String, _ inOut: String) {
        let now = Date()
        addLog(.info, SdkLocalized.format("uwb.area", inOut, name, fid))
        onRawAreaEvent?(fid, name, inOut, now)      // 원본 그대로 — 진단용
        // 가동 중이 아니면 여기서 끝. 수집·전송은 측위 세션 안에서만 한다.
        guard isRunning else { return }
        judge.handleAreaEvent(inOut: inOut, areaName: name, at: now)
    }

    fileprivate func errored(_ code: Int, _ msg: String) {
        addLog(.error, SdkLocalized.format("uwb.error", code, msg, Self.describe(code)))
        onEngineError?(code, msg)
        // 화면 로그에 더해 E-코드로도 올린다 — 관리자는 콘솔 로그 분석기에서 이걸 본다.
        if let sdk = Self.sdkCode(forHubError: code) {
            reportToSDK(sdk, "engine=\(code) \(msg)")
        }
        // 시작 자체가 안 된 경우(1·9·11·12)는 onStopped 가 오지 않는다 — 여기서 되돌린다.
        // 3·7·10 은 구동 중이면 엔진이 스스로 멈추고 onStopped 가 뒤따른다(hubStopped 에서 처리).
        if phase == .starting, [1, 9, 11, 12].contains(code) {
            phase = .idle
            if isRunning { isRunning = false; latestPosition = nil }
            hub.setListener(nil)
        }
    }

    /// 측위 엔진 오류 코드표 (1~12)
    private static func describe(_ code: Int) -> String {
        (1...12).contains(code) ? SdkLocalized.text("uwb.err\(code)")
                                : SdkLocalized.text("uwb.errUnknown")
    }

    // MARK: - 엔진 기동 (측위 시작과 분리)

    /// 엔진을 띄워 층부터 찾는다. 좌표는 아직 쓰지 않는다 — 층이 잡히면 `onFloorDetected` 로
    /// 알리고, 호스트가 건물·층을 자동 선택한다. 측위 가동은 그 뒤 `start()` 가 한다.
    public func startDetection() {
        guard phase == .idle else { return }
        let key = license.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            addLog(.error, SdkLocalized.text("uwb.noLicense"))
            onEngineError?(1, "license not set")
            return
        }
        IntelligenceHub.setLicense(key)
        detectedFloorId = nil
        phase = .starting
        addLog(.info, SdkLocalized.format("uwb.starting", String(key.prefix(8))))

        ensureLocationAuthorization { [weak self] ok in
            guard let self else { return }
            guard ok else { self.abortStart(); return }
            self.launchHub()
        }
    }

    /// 위치 권한을 **순서대로** 확보한다: 기본 권한 → 정밀 위치.
    ///
    /// ⚠️ 순서를 지켜야 한다. `requestTemporaryFullAccuracyAuthorization` 은 기본 권한이
    ///    이미 있어야 동작한다 — 신규 설치 기기에서 이것만 부르면 아무 일도 일어나지 않고,
    ///    엔진이 곧바로 `onError(7)` 로 떨어진다. 증상은 "그냥 측위가 안 됨"뿐이라
    ///    원인을 짚기 어렵다.
    ///
    /// SDK 가 직접 요청하는 이유: 엔진은 권한을 요청하지 않고 검사만 한다(README).
    /// 앱마다 각자 부르게 두면 하나만 빠뜨려도 같은 증상이 난다.
    private func ensureLocationAuthorization(_ done: @escaping (Bool) -> Void) {
        switch locationGate.status {
        case .notDetermined:
            addLog(.info, SdkLocalized.text("uwb.locationAsk"))
            locationGate.requestWhenInUse { [weak self] status in
                guard let self else { return }
                guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                    self.locationDenied(status)
                    done(false)
                    return
                }
                self.ensureFullAccuracy(done)
            }
        case .authorizedWhenInUse, .authorizedAlways:
            ensureFullAccuracy(done)
        default:
            // 거부·제한 — 앱에서 다시 물을 수 없다. 설정 앱으로 안내해야 한다.
            locationDenied(locationGate.status)
            done(false)
        }
    }

    /// 정밀 위치 승격. 사용자가 거절해도 **막지 않는다** — 판단은 엔진이 하고,
    /// 거절이면 onError(7) 로 사유가 분명하게 온다. 여기서 미리 끊으면 그 사유가 사라진다.
    private func ensureFullAccuracy(_ done: @escaping (Bool) -> Void) {
        guard locationGate.accuracy != .fullAccuracy else { done(true); return }
        addLog(.warn, SdkLocalized.text("uwb.fullAccuracy"))
        locationGate.requestFullAccuracy(purposeKey: Self.accuracyPurposeKey) { _ in done(true) }
    }

    private func locationDenied(_ status: CLAuthorizationStatus) {
        addLog(.error, SdkLocalized.text("uwb.locationDenied"))
        reportToSDK(.permissionDenied, "location status=\(status.rawValue)")
        onEngineError?(7, "location authorization denied")
    }

    /// 시작 전 단계에서 되돌린다 — phase 를 .starting 에 남기면 이후 start 가 전부 막힌다.
    private func abortStart() {
        guard phase == .starting else { return }
        phase = .idle
        if isRunning { isRunning = false; latestPosition = nil }
        floorWatchTask?.cancel(); floorWatchTask = nil
    }

    private func launchHub() {
        guard phase == .starting else { return }   // 그 사이 정지됐으면 무시
        hub.setListener(bridge)
        hub.start()
    }

    /// 엔진을 완전히 멈춘다. 측위 중이었으면 그것도 끝난다.
    public func stopDetection() {
        guard phase != .idle, phase != .stopping else { return }
        phase = .stopping
        if isRunning {
            isRunning = false
            latestPosition = nil
        }
        hub.stop()                                   // 정리가 끝나면 onStopped 가 온다
        addLog(.info, SdkLocalized.format("uwb.stopRequested", measurementCount))
    }
}

// MARK: - PositioningProvider (SDK 코어가 start/stop 을 부른다)

@available(iOS 27.0, *)
extension UwbPositioningProvider: PositioningProvider {

    /// 콘솔 건물·층 ID — 코어(applyFloorStateToProvider)가 넣는다.
    public func apply(buildingId: String, floorId: String) {
        self.buildingId = buildingId
        self.floorId = floorId
        addLog(SdkLocalized.format("provider.configApply", String(floorId.prefix(8))))
    }

    /// 콘솔 로케이터·세션·존.
    /// · 앵커·세션은 엔진이 자기 서버에서 받으므로 **주입해도 측위에 쓰이지 않는다** — 진단용.
    /// · 존은 zone_id 매핑용으로 판정기에 꽂는다. 빈 목록도 "없다"는 뜻이라 그대로 반영한다
    ///   (구역을 전부 지운 상황이 엔진에 전달되지 않으면 사라진 구역에서 시책이 계속 발화한다).
    public func apply(config: PositioningConfig) {
        if !config.anchors.isEmpty { anchors = config.anchors }
        judge.apply(zones: config.zones)
        addLog(SdkLocalized.format("uwb.zonesApply", config.zones.count, config.anchors.count))
    }

    // positioningDiagnostic 은 클래스 본문에 있다 (프로토콜 요구사항을 그쪽이 충족한다).

    /// 측위 가동 — 코어가 `begin(provider:)` 에서 부른다.
    /// 엔진이 아직 안 돌고 있으면 여기서 띄운다.
    public func start() {
        guard !isRunning else { return }
        if phase == .idle { startDetection() }
        guard phase != .idle else { return }     // 라이선스 없음 등으로 못 뜬 경우
        measurementCount = 0
        latestPosition = nil
        judge.reset()
        isRunning = true
        warnedFloorMismatch = nil
        addLog(.info, SdkLocalized.format("uwb.positioningOn",
                                          detectedFloorId.map(String.init) ?? "-"))
        startFloorWatch()
        // 입장 트리거 — SDK 가 buildings/floors 로드를 시작하게
        delegate?.provider(self, didEnter: buildingId)
    }

    /// 층 미탐지 감시 — 이미 층이 잡혀 있으면 걸지 않는다.
    private func startFloorWatch() {
        floorWatchTask?.cancel()
        guard detectedFloorId == nil else { return }
        floorWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.floorDetectDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRunning, self.detectedFloorId == nil else { return }
            self.reportToSDK(.floorNotDetected,
                             "phase=\(self.phase.rawValue) after=\(Int(Self.floorDetectDelay))s")
        }
    }

    /// 측위 종료 — 좌표 표시·수집·판정을 끄고 엔진도 함께 멈춘다.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        latestPosition = nil
        floorWatchTask?.cancel(); floorWatchTask = nil
        addLog(.info, SdkLocalized.format("uwb.positioningOff", measurementCount))
        stopDetection()
    }
}

// MARK: - 위치 권한 게이트

/// `CLLocationManager` 를 감싸 "물어보고 답을 기다리는" 한 가지 일만 한다.
///
/// 델리게이트 콜백을 provider 본체에 직접 달지 않는 이유: provider 는 `@MainActor` 인데
/// `CLLocationManagerDelegate` 는 nonisolated 라, 본체에 얹으면 격리 경계가 섞인다.
/// 여기서 한 번 받아 메인으로 넘긴 뒤 클로저로만 돌려준다.
@MainActor
final class LocationAuthGate: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var pending: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var accuracy: CLAccuracyAuthorization { manager.accuracyAuthorization }

    /// 기본(사용 중) 권한 요청. 답이 오면 1회만 콜백한다.
    /// 이미 결정된 상태에서 부르면 시스템이 콜백을 주지 않을 수 있어 즉시 현재 값으로 답한다.
    func requestWhenInUse(_ done: @escaping (CLAuthorizationStatus) -> Void) {
        guard status == .notDetermined else { done(status); return }
        pending = done
        manager.requestWhenInUseAuthorization()
    }

    /// 정밀 위치 임시 승격. purposeKey 는 Info.plist 사전의 키와 같아야 한다.
    func requestFullAccuracy(purposeKey: String, _ done: @escaping (Bool) -> Void) {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey) { [weak self] _ in
            Task { @MainActor in done(self?.accuracy == .fullAccuracy) }
        }
    }

    // manager 를 캡처하지 않는다 — Sendable 이 아니라 경계를 넘길 수 없다.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.deliver() }
    }

    private func deliver() {
        guard status != .notDetermined, let done = pending else { return }
        pending = nil
        done(status)
    }
}

// MARK: - 브리지 (엔진 백그라운드 큐 → 메인)

@available(iOS 27.0, *)
private final class ListenerBridge: HubListener {
    weak var owner: UwbPositioningProvider?

    private func onMain(_ body: @escaping @MainActor (UwbPositioningProvider) -> Void) {
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
