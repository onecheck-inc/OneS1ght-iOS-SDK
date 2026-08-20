//
//  OneS1ght.swift
//  공개 진입점 — 호스트 앱이 보는 유일한 표면.
//
//  설계 규칙: "문은 static, 부품은 인스턴스".
//  · 문(이 클래스) — 앱 전체에 하나뿐인 진입점. private init 이라 인스턴스화 불가, 전부 static.
//  · 부품(coordinator·ApiClient·엔진) — 키 교체·reset 때 갈아끼우는 인스턴스. 밖에 안 보임.
//  하나만 존재해야 하는 이유: UWB 라디오·PRM 엔진·Keychain ID·좌표 버퍼가 기기당 1개라
//  세션이 여럿이면 서로 충돌한다.
//
//  사용 (호스트 앱):
//    // ① 앱 시작 시 — 기기 게이트 + 키 검증 + 테넌트 설정 수신
//    try await OneS1ght.initialize(sdkKey: "ock_…", geospaceKey: "gsk_…")
//    // ② 공간 선택 — 필수. 이걸 안 하면 좌표가 나오지 않는다
//    let buildings = try await OneS1ght.buildings()
//    let infra = try await OneS1ght.loadFloor(buildingId: b.id, floorId: f.id)
//    // ③ 매장 진입 시 — 측위 가동
//    OneS1ght.onTriggers = { zoneId, triggers in ... }   // 쿠폰 등 액션 수신
//    try await OneS1ght.start(consent: userConsented)
//    OneS1ght.identify(customerId: "cust_123")           // (선택) 로그인 시
//    await OneS1ght.stop()                               // 재시작 가능 (초기화 유지)
//

import Foundation

@MainActor
public final class OneS1ght {

    private init() {}   // 인스턴스 생성 차단 — 진입점은 타입 자체 (전부 static)

    /// SDK 버전 (verify의 client.sdk_version에 실림)
    public static let sdkVersion = "0.1.0"

    // MARK: - 콜백

    /// 구역(Zone) 진입/이탈/체류 이벤트 — 온디바이스 판정 즉시 (서버 왕복 없음).
    /// 앱 내 실시간 반응(쿠폰·안내 등)을 붙이는 표준 훅.
    public static var onZoneEvent: ((ZoneEvent) -> Void)?

    /// 존 이벤트 응답의 개인화 액션(triggers) 수신 — (zoneId, [Trigger])
    public static var onTriggers: ((String, [Trigger]) -> Void)?

    /// 실시간 좌표 (도면 로컬 미터) — 지도에 내 위치를 그리는 표준 훅.
    /// 서버 전송과 무관하게 좌표가 나올 때마다 호출된다 (최대 4회/초).
    public static var onPosition: ((Coordinates) -> Void)?

    /// SDK 내부 활동 로그 (디버그용) — verify·좌표 flush·zone 전송의 성공/실패 통지.
    /// 데모/개발 중 "전송이 실제로 되고 있나"를 눈으로 확인하는 용도. 운영에선 미등록 권장.
    public static var onDebugLog: ((String) -> Void)?

    // MARK: - 상태

    /// B2C 유저 익명 ID (Keychain 영속)
    public static var anonUserId: String { identity.anonUserId }

    /// 세션 가능 상태인가 (initialize 성공 = 기기 통과 + 키 유효 + 설정 로드됨)
    public static var isInitialized: Bool { coordinator?.isPrepared ?? false }

    /// 측위 가능 여부 — 사유 포함. 앱이 사전 안내 UI 를 분기할 때 쓴다.
    public enum PositioningAvailability: Equatable {
        case available            // 측위 가능
        case osVersionTooLow      // iOS 27 미만 — "OS 업데이트 후 사용 가능" 안내
        case deviceNotSupported   // UWB(DL-TDoA) 칩 미지원 — "iPhone 12 이상 필요" 안내
    }

    /// 이 기기에서 측위가 가능한가 + 불가 사유. initialize 전에도 호출 가능 (throw 없음).
    /// OS 버전을 먼저 검사한다 — 구 OS 에선 칩 지원 여부를 물을 API 자체가 없어,
    /// 업데이트로 해결될 수 있는 기기에 deviceNotSupported 를 잘못 알려주지 않기 위함.
    public static var positioningAvailability: PositioningAvailability {
        #if os(iOS)
        guard #available(iOS 27.0, *) else { return .osVersionTooLow }
        return UwbPositioningProvider.isSupported ? .available : .deviceNotSupported
        #else
        return .deviceNotSupported
        #endif
    }

    /// 이 기기에서 측위가 가능한가 (요약형). 사유가 필요하면 positioningAvailability 사용.
    public static var isPositioningAvailable: Bool { positioningAvailability == .available }

    // MARK: - 생명주기

    /// 초기화 (앱 시작 시 1회) — 기기 게이트 → 키 검증 + 테넌트 SDK 설정 수신.
    /// 통과하면 "이 기기에서 이 키로 측위 세션 가능" 확정.
    /// verify 한 번으로 키 유효성과 백엔드 도달 가능 여부를 함께 확인한다.
    /// 실패 사유는 throw (osVersionTooLow/deviceNotSupported/invalidKey/positioningDisabled/network).
    /// 실패 시 재호출 = 재시도 · 성공 후 재호출 = 무시(멱등) · 다른 키로 재호출 = 세션 재구성.
    /// - sdkKey: OneS1ght 콘솔 발급 (ock_) — 인증·존·수집·이벤트·도면
    /// - geospaceKey: GeoSpace 발급 (gsk_) — 앵커·세션·층 목록.
    ///   서버 통합이 끝나면 불필요해지는 과도기 인자 — 생략 시 측위만 비활성, 나머진 동작.
    /// - baseURL: 자체 서버를 구축한 고객만. 운영/개발 구분은 이 인자가 아니라
    ///   콘솔이 발급하는 키(production/development)가 가른다.
    /// ⚠️ 건물·층은 조회하지 않는다 — 공간 선택은 buildings()/loadFloor() 의 책임이다.
    /// loadFloor 없이 start() 하면 측위 파이프라인은 돌지만 좌표가 나오지 않는다(로그로 통지).
    public static func initialize(sdkKey: String,
                                  geospaceKey: String? = nil,
                                  baseURL: URL = ApiClient.defaultBaseURL) async throws {
        // ① 기기 게이트 — 측위 불가 기기는 세션 전체가 무의미하므로 네트워크 타기 전에 사유와 함께 거부.
        //    시뮬레이터는 예외: 개발·테스트 환경 전용이고 스토어 배포가 불가능해 프로덕션 우회 경로가 없다.
        //    (시뮬레이터에서도 실측위는 start()의 내장 UWB 게이트가 막는다 — Mock provider 주입만 가능)
        #if os(iOS) && !targetEnvironment(simulator)
        switch positioningAvailability {
        case .osVersionTooLow:    throw SdkError.osVersionTooLow
        case .deviceNotSupported: throw SdkError.deviceNotSupported
        case .available:          break
        }
        #endif

        // ② 키가 바뀌었으면 세션 재구성 — "새 키로 initialize = 새 키로 시작"이라는 직관 보장.
        //    (재구성 없이 두면 이전 키로 만든 ApiClient 를 조용히 재사용해 '맞는 키인데 401' 함정이 생긴다)
        if let stored = storedKeys, stored != (sdkKey, geospaceKey) {
            await coordinator?.stop()
            coordinator = nil
        }

        // ③ 세션 구성 (최초 또는 재구성 후 1회)
        if coordinator == nil {
            let geospace = geospaceKey.map {
                GeospaceClient(keys: .init(sdk: sdkKey, geospace: $0))
            }
            let c = SessionCoordinator(api: ApiClient(apiKey: sdkKey, baseURL: baseURL),
                                       identity: identity,
                                       geospace: geospace)
            c.onTriggers = { zoneId, triggers in OneS1ght.onTriggers?(zoneId, triggers) }
            c.onPosition = { coord in OneS1ght.onPosition?(coord) }
            c.onLog = { line in OneS1ght.onDebugLog?(line) }
            coordinator = c
            storedKeys = (sdkKey, geospaceKey)
        }

        // ④ 키 검증 + 설정 프리페치 (실패 시 throw — 재호출이 곧 재시도)
        try await coordinator?.prepare()
    }

    /// 시작 (매장 진입 시) — 내장 UWB 측위로 가동. 고객사가 쓰는 표준 경로.
    /// - consent: 위치정보 수집 동의 (호스트가 취득). false면 수집 미시작 (.consentRequired)
    /// - throws: .notInitialized / .consentRequired / .deviceNotSupported / .osVersionTooLow / ApiError
    public static func start(consent: Bool) async throws {
        #if os(iOS)
        guard #available(iOS 27.0, *) else { throw SdkError.osVersionTooLow }
        // 시뮬레이터는 여기서 막힌다 (UWB 칩 없음 → isSupported false).
        // 시뮬레이터 테스트는 start(consent:provider:) 로 Mock 을 주입하는 경로만 열려 있다.
        guard UwbPositioningProvider.isSupported else { throw SdkError.deviceNotSupported }
        let uwb = (builtInProvider as? UwbPositioningProvider) ?? UwbPositioningProvider()
        builtInProvider = uwb
        uwb.onZoneEvent = { event in OneS1ght.onZoneEvent?(event) }
        uwb.onLog = { line in OneS1ght.onDebugLog?(line) }   // 엔진 로그 → 표준 디버그 훅
        try await start(consent: consent, provider: uwb)
        #else
        throw SdkError.deviceNotSupported
        #endif
    }

    /// 시작 (커스텀 측위 주입) — 테스트(Mock)·데모(UI 관찰용 provider 직접 보유) 등 특수 경우용.
    public static func start(consent: Bool, provider: PositioningProvider) async throws {
        guard let coordinator else { throw SdkError.notInitialized }   // initialize 자체를 안 부른 경우
        // 일시 장애 회복 — initialize 가 네트워크 순단으로 실패했더라도 시작 시점에 준비를 마저 시도한다
        // (키는 보관돼 있음). 결정적 실패(잘못된 키 등)는 같은 사유로 다시 throw 되므로 거짓 신호는 없다.
        if !coordinator.isPrepared { try await coordinator.prepare() }
        try await coordinator.start(consent: consent, provider: provider)
        if let customerId { coordinator.identify(customerId: customerId) }   // start 전 identify 반영
    }

    /// 종료: 측위 정지 + 잔여 좌표 flush. 초기화 상태는 유지 → start 재호출로 재시작 가능.
    public static func stop() async {
        await coordinator?.stop()
    }

    /// 초기화 리셋 — 세션을 버린다. 이후 initialize(sdkKey:)로 다른 키로 재초기화 가능
    /// (앱 재빌드 없이 런타임에 키 교체용).
    public static func reset() async {
        await coordinator?.stop()
        coordinator = nil
        storedKeys = nil
    }

    // MARK: - 공간 설정

    /// 빌딩/층 트리 (선택 UI용). geospaceKey 없이 초기화했으면 빈 배열.
    public static func buildings() async throws -> [SpaceBuilding] {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.buildings()
    }

    /// 층 인프라 로드 — 도면(앱 렌더용)을 돌려주고, 앵커·세션·존은 SDK 가 내부 엔진에 주입한다.
    /// start 전이면 start 가 반영하고, 가동 중이면 즉시 층 전환.
    @discardableResult
    public static func loadFloor(buildingId: String, floorId: String) async throws -> FloorInfra {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.loadFloor(buildingId: buildingId, floorId: floorId)
    }

    /// 현재 층의 존만 재조회 (경량 — 도면 재다운로드 없음). 콘솔에서 존을 바꿨을 때 폴링용.
    /// 받은 존은 판정 엔진에도 즉시 반영된다.
    @discardableResult
    public static func refreshZones() async -> [Zone] {
        await coordinator?.refreshZones() ?? []
    }

    // MARK: - 사용자

    /// (선택) 고객사 회원 ID 연결 — 로그인 후 호출, 로그아웃 시 nil
    public static func identify(customerId: String?) {
        self.customerId = customerId
        coordinator?.identify(customerId: customerId)
    }

    // MARK: - 내부 부품 (인스턴스 — 키 교체·reset 때 갈아끼움)

    private static let identity = IdentityStore()
    private static var coordinator: SessionCoordinator?
    private static var customerId: String?
    private static var builtInProvider: PositioningProvider?          // 내장 provider 재사용 (재시작 대비)
    private static var storedKeys: (sdk: String, geospace: String?)?  // 키 교체 감지용
}
