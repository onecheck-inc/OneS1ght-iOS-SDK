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
//    try await OneS1ght.initialize(sdkKey: "ock_…", geoSdkKey: "gsk_…")
//    // ② 공간 선택 — 필수. 이걸 안 하면 좌표가 나오지 않는다
//    let buildings = try await OneS1ght.buildings()
//    let floors = try await OneS1ght.floors(buildings[0].id)
//    try await OneS1ght.setFloorMap(floors[0], buildingID: buildings[0].id)
//    // ③ 프로필 연결 — createProfile 로 발급받아 앱이 보관한 값
//    OneS1ght.identify(profileId: "pf_8a3c")
//    // ④ 매장 진입 시 — 측위 가동
//    let session = try OneS1ght.floorSession()
//    session.onTriggers = { zoneId, triggers in ... }    // 쿠폰 등 액션 수신
//    try await session.begin()
//    await session.end()                                 // 재시작 가능 (초기화 유지)
//

import Foundation

@MainActor
public final class OneS1ght {

    private init() {}   // 인스턴스 생성 차단 — 진입점은 타입 자체 (전부 static)

    /// SDK 버전 (verify의 client.sdk_version에 실림)
    public static let sdkVersion = "0.1.5"

    // MARK: - 콜백

    /// SDK 내부 활동 로그 (디버그용) — verify·좌표 flush·zone 전송의 성공/실패 통지.
    /// 데모/개발 중 "전송이 실제로 되고 있나"를 눈으로 확인하는 용도. 운영에선 미등록 권장.
    public static var onDebugLog: ((String) -> Void)?

    // MARK: - 상태

    /// 세션 가능 상태인가 (initialize 성공 = 기기 통과 + 키 유효 + 설정 로드됨)
    public static var isInitialized: Bool { coordinator?.isPrepared ?? false }

    /// 측위 가능 여부 — 사유 포함. 앱이 사전 안내 UI 를 분기할 때 쓴다.
    public enum DeviceAvailability: Equatable {
        case available            // 측위 가능
        case osVersionTooLow      // iOS 27 미만 — "OS 업데이트 후 사용 가능" 안내
        case deviceNotSupported   // UWB(DL-TDoA) 칩 미지원 — "iPhone 12 이상 필요" 안내
    }

    /// 이 기기에서 측위가 가능한가 + 불가 사유. initialize 전에도 호출 가능 (throw 없음).
    /// OS 버전을 먼저 검사한다 — 구 OS 에선 칩 지원 여부를 물을 API 자체가 없어,
    /// 업데이트로 해결될 수 있는 기기에 deviceNotSupported 를 잘못 알려주지 않기 위함.
    public static var deviceAvailability: DeviceAvailability {
        #if os(iOS)
        guard #available(iOS 27.0, *) else { return .osVersionTooLow }
        return UwbPositioningProvider.isSupported ? .available : .deviceNotSupported
        #else
        return .deviceNotSupported
        #endif
    }

    /// 이 기기에서 측위가 가능한가 (요약형). 사유가 필요하면 deviceAvailability 사용.
    public static var isDeviceAvailable: Bool { deviceAvailability == .available }

    // MARK: - 권한

    /// 측위 권한 확인. **호출하면 시스템 팝업이 뜬다** — 확인과 요청이 분리되지 않는다.
    ///
    /// NearbyInteraction 에는 상태만 읽는 API 가 없어(iOS 26.5 SDK 헤더 전수 확인),
    /// NISession 을 실제로 띄워 보는 것이 유일한 확인 수단이다. 그래서 SDK 가 시점을
    /// 정하지 않고 이 문을 따로 열어 둔다 — 앱이 적절한 맥락에서 부르면 된다.
    ///
    ///     try await OneS1ght.initialize(sdkKey: "ock_…", geoSdkKey: "gsk_…")
    ///     switch await OneS1ght.permissions() {
    ///     case .authorized:  break
    ///     case .denied:      showSettingsGuide()   // 앱에서 재요청 불가 — 설정 앱으로
    ///     case .unsupported: showUnsupportedNotice()
    ///     }
    ///
    /// 이미 한 번 답한 권한이면 팝업 없이 즉시 돌아온다.
    /// initialize 를 부르지 않았어도 호출할 수 있다 (기기 조건만 보는 검사라서).
    /// - Returns: `.authorized` · `.denied` · `.unsupported`
    ///   (30초 안에 응답이 없으면 보수적으로 `.denied`)
    public static func permissions() async -> PermissionStatus {
        #if os(iOS)
        guard deviceAvailability == .available else { return .unsupported }
        guard #available(iOS 27.0, *) else { return .unsupported }
        return await NIPermissionProbe().run()
        #else
        return .unsupported
        #endif
    }

    // MARK: - 생명주기

    /// 초기화 (앱 시작 시 1회) — 기기 게이트 → 키 검증 + 테넌트 SDK 설정 수신.
    /// 통과하면 "이 기기에서 이 키로 측위 세션 가능" 확정.
    /// verify 한 번으로 키 유효성과 백엔드 도달 가능 여부를 함께 확인한다.
    /// 실패 사유는 throw (osVersionTooLow/deviceNotSupported/invalidKey/positioningDisabled/network).
    /// 실패 시 재호출 = 재시도 · 성공 후 재호출 = 무시(멱등) · 다른 키로 재호출 = 세션 재구성.
    /// - sdkKey: OneS1ght 콘솔 발급 (ock_) — 인증·존·수집·이벤트·도면
    /// - geoSdkKey: GeoSpace 발급 (gsk_) — 앵커·세션·층 목록.
    ///   서버 통합이 끝나면 불필요해지는 과도기 인자 — 생략 시 측위만 비활성, 나머진 동작.
    /// - baseURL: 자체 서버를 구축한 고객만. 운영/개발 구분은 이 인자가 아니라
    ///   콘솔이 발급하는 키(production/development)가 가른다.
    /// ⚠️ 건물·층은 조회하지 않는다 — 공간 선택은 buildings()/setFloorMap() 의 책임이다.
    /// setFloorMap 없이 begin() 하면 측위 파이프라인은 돌지만 좌표가 나오지 않는다(E3001 로 통지).
    public static func initialize(sdkKey: String,
                                  geoSdkKey: String? = nil,
                                  baseURL: URL = ApiClient.defaultBaseURL) async throws {
        // ① 기기 게이트 — 측위 불가 기기는 세션 전체가 무의미하므로 네트워크 타기 전에 사유와 함께 거부.
        //    시뮬레이터는 예외: 개발·테스트 환경 전용이고 스토어 배포가 불가능해 프로덕션 우회 경로가 없다.
        //    (시뮬레이터에서도 실측위는 begin()의 내장 UWB 게이트가 막는다 — Mock provider 주입만 가능)
        #if os(iOS) && !targetEnvironment(simulator)
        switch deviceAvailability {
        case .osVersionTooLow:    throw SdkError.osVersionTooLow
        case .deviceNotSupported: throw SdkError.deviceNotSupported
        case .available:          break
        }
        #endif

        // ② 키가 바뀌었으면 세션 재구성 — "새 키로 initialize = 새 키로 시작"이라는 직관 보장.
        //    (재구성 없이 두면 이전 키로 만든 ApiClient 를 조용히 재사용해 '맞는 키인데 401' 함정이 생긴다)
        if let stored = storedKeys, stored != (sdkKey, geoSdkKey) {
            await coordinator?.stop()
            coordinator = nil
        }

        // ③ 세션 구성 (최초 또는 재구성 후 1회)
        if coordinator == nil {
            let geospace = geoSdkKey.map {
                GeospaceClient(keys: .init(sdk: sdkKey, geospace: $0))
            }
            let c = SessionCoordinator(api: ApiClient(apiKey: sdkKey, baseURL: baseURL),
                                       identity: identity,
                                       geospace: geospace)
            // 좌표·트리거는 세션 콜백으로 흘린다 (전역 훅은 onDebugLog 만 남았다)
            c.onTriggers = { zoneId, triggers in FloorSession.shared.onTriggers?(zoneId, triggers) }
            c.onPosition = { coord in FloorSession.shared.onPosition?(coord) }
            c.onLog = { line in OneS1ght.onDebugLog?(line) }
            coordinator = c
            storedKeys = (sdkKey, geoSdkKey)
        }

        // ④ 키 검증 + 설정 프리페치 (실패 시 throw — 재호출이 곧 재시도)
        try await coordinator?.prepare()
    }

    /// 초기화 리셋 — 세션을 버린다. 이후 initialize(sdkKey:)로 다른 키로 재초기화 가능
    /// (앱 재빌드 없이 런타임에 키 교체용).
    public static func reset() async {
        await coordinator?.stop()
        coordinator = nil
        storedKeys = nil
    }

    // MARK: - 공간 조회 (엔드포인트 하나당 메서드 하나 · 목록 ↔ 단건)

    /// 건물 목록. geoSdkKey 없이 초기화했으면 빈 배열. 층은 floors() 로 따로.
    public static func buildings() async throws -> [Building] {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.buildings()
    }

    /// 건물 단건.
    public static func building(_ buildingID: String) async throws -> Building {
        guard let b = try await buildings().first(where: { $0.id == buildingID }) else {
            throw ApiError.notFound(detail: buildingID)
        }
        return b
    }

    /// 층 목록 — 이름·치수는 채워지고 **도면 이미지는 비어 있다**(목록 경량화).
    /// 지도를 그릴 층만 floor() 단건으로 받으면 이미지가 채워져 온다.
    public static func floors(_ buildingID: String) async throws -> [Floor] {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.floors(buildingId: buildingID)
    }

    /// 층 단건 — 도면 이미지 포함 (floors() 가 캐시를 데워 두면 추가 왕복 없음).
    public static func floor(_ buildingID: String, _ floorID: String) async throws -> Floor {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.floor(buildingId: buildingID, floorId: floorID)
    }

    /// 존 목록 (판정 파라미터 포함).
    public static func zones(_ buildingID: String, _ floorID: String) async throws -> [Zone] {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.zones(buildingId: buildingID, floorId: floorID)
    }

    /// 존 단건.
    public static func zone(_ buildingID: String, _ floorID: String,
                            _ zoneID: String) async throws -> Zone {
        guard let z = try await zones(buildingID, floorID).first(where: { $0.id == zoneID }) else {
            throw ApiError.notFound(detail: zoneID)
        }
        return z
    }

    /// 로케이터 + 세션ID — sessionId 는 별도 API 가 아니라 이 응답에 함께 실려 온다.
    public static func locators(_ buildingID: String,
                                _ floorID: String) async throws -> FloorLocators {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.locators(buildingId: buildingID, floorId: floorID)
    }

    // MARK: - 층 지정

    /// 측위·판정에 쓸 층을 지정한다. 호출할 때마다 갱신되고, nil 이면 비운다.
    /// 로케이터·sessionId·존을 받아 엔진에 주입한다 — 가동 중이면 즉시 층 전환.
    public static func setFloorMap(_ floor: Floor?, buildingID: String? = nil) async throws {
        guard let coordinator else { throw SdkError.notInitialized }
        try await coordinator.setFloorMap(floor, buildingId: buildingID ?? currentBuildingID)
        currentBuildingID = floor == nil ? nil : (buildingID ?? currentBuildingID)
    }

    /// 현재 층의 존만 재조회 (경량 — 도면 재다운로드 없음). 콘솔에서 존을 바꿨을 때 폴링용.
    /// 받은 존은 판정 엔진에도 즉시 반영된다.
    @discardableResult
    public static func refreshZones() async -> [Zone] {
        await coordinator?.refreshZones() ?? []
    }

    // MARK: - 측위 세션

    /// 현재 설정된 층의 측위 세션. setFloorMap 이 선행되어야 한다.
    /// 항상 같은 인스턴스를 돌려준다(싱글턴) — UWB 라디오·판정 엔진·좌표 버퍼가
    /// 기기당 하나뿐이라 세션이 여럿이면 물리적으로 충돌한다.
    public static func floorSession() throws -> FloorSession {
        guard coordinator != nil else { throw SdkError.notInitialized }
        return FloorSession.shared
    }

    // MARK: - 프로필

    /// 프로필 생성 — 서버가 발급한 profileId 를 돌려준다. **앱이 보관해 재사용해야 한다.**
    /// 속성은 고객사 자유(성별·연령대·관심사 등).
    /// ⚠️ 나이는 정확값 대신 연령대("20s")로 넣기를 권한다 — 성별·관심사·동선과 조합되면
    ///    재식별 가능성이 생긴다.
    public static func createProfile(_ attributes: [String: String]) async throws -> String {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.createProfile(attributes)
    }

    /// 프로필 조회.
    public static func getProfile(_ profileId: String) async throws -> [String: String] {
        guard let coordinator else { throw SdkError.notInitialized }
        return try await coordinator.getProfile(profileId)
    }

    /// 프로필 속성 전체 교체.
    public static func putProfile(_ profileId: String,
                                  _ attributes: [String: String]) async throws {
        guard let coordinator else { throw SdkError.notInitialized }
        try await coordinator.putProfile(profileId, attributes)
    }

    /// 프로필 삭제.
    public static func deleteProfile(_ profileId: String) async throws {
        guard let coordinator else { throw SdkError.notInitialized }
        try await coordinator.deleteProfile(profileId)
    }

    // MARK: - 버퍼

    /// 쌓인 좌표를 지금 서버로 전송 (300건/60초를 기다리지 않고 앞당김).
    public static func send() async {
        await coordinator?.sendNow()
    }

    /// 쌓인 좌표를 **전송하지 않고 폐기**.
    /// ⚠️ flush 가 아니라 empty 인 이유 — 통상 flush 는 "쌓인 것을 목적지로 밀어낸다"(전송)는
    ///    뜻이라, 폐기에 그 이름을 쓰면 전송으로 오해한 호출에 데이터가 조용히 사라진다.
    public static func empty() {
        coordinator?.discardPending()
    }

    // MARK: - 사용자

    /// 프로필 연결 — 좌표·존 이벤트가 이 ID 로 귀속된다.
    /// createProfile() 로 발급받아 앱이 보관한 값을 넘긴다(로그아웃 등 해제는 nil).
    /// 고객사 회원 ID ↔ profileId 매핑은 고객사만 보관한다 — 회원 ID 는 OneS1ght 에 오지 않는다.
    /// begin() 전에 반드시 호출해야 한다 (없으면 .notIdentified · E1004).
    public static func identify(profileId: String?) {
        self.profileId = profileId
        coordinator?.identify(profileId: profileId)
    }

    // MARK: - 내부 부품 (인스턴스 — 키 교체·reset 때 갈아끼움)

    private static let identity = IdentityStore()
    private static var coordinator: SessionCoordinator?
    private static var profileId: String?
    private static var currentBuildingID: String?             // setFloorMap 의 건물 문맥
    /// FloorSession 이 코디네이터에 닿는 통로 (같은 모듈 내부 전용)
    static var coordinatorRef: SessionCoordinator? { coordinator }
    private static var storedKeys: (sdk: String, geospace: String?)?  // 키 교체 감지용
}
