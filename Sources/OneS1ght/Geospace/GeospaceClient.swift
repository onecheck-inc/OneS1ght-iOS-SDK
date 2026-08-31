//
//  GeospaceClient.swift
//  OneS1ght
//
//  ⚠️ SDK 내부 전용 — 호스트 앱은 이 타입을 모른다.
//     고객사는 initialize(apiKey:geoSdkKey:) 로 키 2개만 넘기고,
//     앵커·세션·도면·존이 어디서 오는지는 SDK 사정으로 감춘다.
//
//  GeoSpace(geoplan.io) 연동 — 한 호스트, 두 키.
//  · /api/m/floors/{id}/plan       (gsk_, X-SDK-Key)    → 도면 이미지(base64) + widthM + origin
//  · /api/m/floors/{id}/anchors    (gsk_, X-SDK-Key)    → 앵커(도면 로컬 미터 0~13)
//  · 존은 콘솔(ock_)에서 — 파트너 키(gpk_)는 존 쓰기 권한이 있어 클라이언트 배포 금지
//  모든 좌표가 0~13 프레임(origin 0,0)이라 변환(÷57.7·Y플립) 불필요.
//  (console /positioning/floors 는 HTML 회귀로 사용 불가 → 파트너 zones 로 대체.)
//

import Foundation
import simd

@MainActor
final class GeospaceClient {

    /// 호스트가 initialize 로 넘긴 키 묶음
    struct Keys { let sdk: String; let geospace: String }
    private let keys: Keys
    /// session 은 테스트에서 URLProtocol 스텁을 물리기 위한 주입점이다(ApiClient 와 같은 방식).
    init(keys: Keys, session: URLSession = .shared) {
        self.keys = keys
        self.session = session
    }

    private let host = "geospace.geoplan.io"

    // 공개 타입(SpaceBuilding/SpaceFloor/AnchorPoint/FloorInfra)은 Models/SpaceModels.swift.
    // 존은 SDK 공통 타입(Zone/Position)을 그대로 쓴다 — ZoneEngine 에 변환 없이 주입된다.

    private(set) var status: String = SdkLocalized.text("gs.idle")

    // TLS 검증은 표준 그대로 — SDK 는 인증서 우회를 하지 않는다 (ApiClient 와 동일 원칙)
    private let session: URLSession

    enum GsError: Error { case badResponse(Int), noImage, decode }

    // MARK: - 공개 진입점

    /// 건물 목록 — 콘솔(ock_)이 기본, 실패 시 GeoSpace 폴백. 층은 담지 않는다.
    /// floorCount 는 서버가 응답에 실어줄 때까지 nil (floor_count TBD).
    func loadBuildings() async throws -> [Building] {
        do {
            let base = ApiClient.defaultBaseURL.absoluteString
            let list: ConsoleBuildingsResponse = try await consoleGet("\(base)/positioning/buildings")
            let out = list.buildings
                .filter { !$0.buildingId.hasPrefix("sim-") }   // GeoSpace 미연동 sim 매장 제외
                .map { Building(id: $0.buildingId, name: $0.name, floorCount: $0.floorCount) }
            guard !out.isEmpty else { throw GsError.decode }
            return out
        } catch {
            let res: BuildingsResponse = try await get("api/m/buildings")
            return res.buildings.map { Building(id: $0.buildingId, name: $0.buildingName,
                                                floorCount: $0.floors.count) }
        }
    }

    /// 층 목록 — 이름·hasPlan 만 채우고 **도면은 받지 않는다.**
    ///
    /// 예전에는 이름을 얻으려고 층마다 plan 을 불렀다. plan 응답은 prod 실측 888KB 라
    /// 층이 N개면 드롭다운이 뜨기 전에 888KB × N 을 순서대로 받았다 — "빌딩을 고르면 층이
    /// 한참 뒤에 뜬다"의 원인이다. 이름은 이 응답이 이미 주고 있었고, 도면 유무도 서버가
    /// 실어 주게 됐다. 도면은 실제로 열 층 하나만 floor(단건)에서 받으면 된다.
    ///
    /// 콘솔 층이 비면(존 0개 등) GeoSpace 건물 트리로 우회한다 — 그쪽도 이름·도면 유무를 준다.
    func loadFloors(buildingId: String) async throws -> [Floor] {
        let base = ApiClient.defaultBaseURL.absoluteString
        if let fl: ConsoleFloorsResponse =
            try? await consoleGet("\(base)/positioning/buildings/\(buildingId)/floors"),
           !fl.floors.isEmpty {
            return fl.floors.map {
                Floor(id: $0.floorId,
                      name: $0.name ?? String($0.floorId.prefix(8)),
                      hasPlan: $0.hasPlan ?? false)
            }
        }
        // 콘솔 미러가 비었을 때만 — GeoSpace 건물 트리도 이름·도면 유무를 함께 준다.
        let res: BuildingsResponse = try await get("api/m/buildings")
        let floors = res.buildings.first { $0.buildingId == buildingId }?.floors ?? []
        return floors.map { Floor(id: $0.floorId, name: $0.floorName, hasPlan: $0.hasPlan) }
    }

    /// 층 단건 — 도면 이미지까지 채워 반환. loadFloors 가 캐시를 데워 두면 왕복 없음.
    func loadFloor(buildingId: String, floorId: String) async throws -> Floor {
        let plan = try? await consolePlan(buildingId, floorId)
        return makeFloor(id: floorId, from: plan, withImage: true)
    }

    /// ConsolePlanResponse → Floor. withImage=false 면 치수·이름만 채우고 PNG 는 뺀다.
    private func makeFloor(id: String, from plan: ConsolePlanResponse?, withImage: Bool) -> Floor {
        guard let plan, let img = plan.plan?.image else {
            return Floor(id: id, name: plan?.floorName ?? String(id.prefix(8)),
                         hasPlan: plan?.hasPlan ?? false)
        }
        let heightM = img.widthM * Double(img.imgH) / Double(img.imgW)
        return Floor(id: id,
                     name: plan.floorName ?? String(id.prefix(8)),
                     image: withImage ? img.pngData() : nil,
                     hasPlan: plan.hasPlan,
                     originX: img.originX, originY: img.originY,
                     widthM: img.widthM, heightM: heightM)
    }

    /// 로케이터 + 세션ID — 측위 시작에 필요한 전부. GeoSpace 앵커 API 에서 온다.
    func loadLocators(buildingId: String, floorId: String) async throws -> FloorLocators {
        let res = try await getAnchors(floorId)
        return FloorLocators(locators: res.anchors.compactMap { $0.toLocator() },
                             sessionId: res.anchors.first?.sessionId)
    }

    /// 측위·판정 재료(로케이터·세션·존) 로드 — setFloorMap 이 부른다.
    /// 도면 이미지는 여기 없다(지도는 Floor 로 그린다). 단 존 픽셀→미터 정규화에
    /// 도면 치수가 필요해 plan 메타는 여전히 읽는다(캐시 재사용).
    ///
    /// ⚠️ **도면이 없는 층은 오류가 아니다.** 매장은 도면을 올리지만 산업 현장처럼 올릴
    ///    도면 자체가 없는 곳이 있다. 예전에는 여기서 도면을 반드시 있는 것으로 보고
    ///    `getPlan` 이 던졌고, 그 바람에 도면뿐 아니라 **로케이터·세션·존까지 통째로**
    ///    못 받아 그런 층은 측위 자체가 불가능했다(앱에는 "지도 조회 실패"로만 보였다).
    ///    좌표는 도면이 아니라 로케이터 배치에서 나오므로, 도면이 없어도 측위는 정상이다.
    func loadFloorState(buildingId: String, floorId: String) async throws -> FloorState {
        status = SdkLocalized.text("gs.loading")
        async let planTask = planImageIfAny(buildingId: buildingId, floorId)
        async let anchorTask = getAnchors(floorId)
        async let zoneTask = getZones(buildingId: buildingId, floorId)
        let (planImage, anchorRes) = try await (planTask, anchorTask)
        let zonesRaw = await zoneTask

        let zones = normalizeZones(zonesRaw, image: planImage)
        let state = FloorState(
            buildingId: buildingId,
            floorId: floorId,
            sessionId: anchorRes.anchors.first?.sessionId,
            locators: anchorRes.anchors.compactMap { $0.toLocator() },
            zones: zones,
            hasPlan: planImage != nil
        )
        status = SdkLocalized.format("gs.done", state.locators.count, zones.count)
        return state
    }

    // MARK: - 엔드포인트

    // 세션 캐시 — plan 은 정적(층이름 겸 선로딩), 앵커는 전원상태(clusterStatus)가 변할 수 있어 TTL
    private var planCache: [String: ConsolePlanResponse] = [:]                 // floorId → plan
    private var anchorCache: [String: (at: Date, res: AnchorResponse)] = [:]   // floorId → 앵커 (TTL 3분)

    /// 도면 — console 프록시(§6.4b) 우선(+세션 캐시), 실패 시 GeoSpace 직행 폴백.
    /// **도면이 없는 층이면 nil.** 던지지 않는다 — loadFloorState 주석 참고.
    ///
    /// 콘솔이 `has_plan: false` 라고 **명시**하면 거기서 끝낸다. 예전에는 그때도 GeoSpace
    /// 직행으로 폴백했는데, 그쪽 응답 타입은 이미지가 옵셔널이 아니라 디코드에서 던졌다 —
    /// "도면이 없다"는 정상 사실이 통신 오류로 둔갑하던 자리다.
    /// 콘솔 **조회 자체가 실패**했을 때만(오래된 서버·네트워크) 폴백을 탄다. 그 폴백마저
    /// 실패하면 그때도 nil 이다: 도면을 못 받은 것과 도면이 없는 것을 화면에서 구분할
    /// 방법이 없고, 어느 쪽이든 측위를 막을 이유는 없다.
    private func planImageIfAny(buildingId: String, _ floorId: String) async -> PlanImage? {
        if let res = try? await consolePlan(buildingId, floorId) {
            guard res.hasPlan, let body = res.plan else { return nil }
            return body.image
        }
        let fallback: PlanResponse? = try? await get("api/m/floors/\(floorId)/plan")
        return fallback?.image
    }

    /// console 도면 프록시 (snake_case → convertFromSnakeCase 로 PlanImage 재사용). 층별 캐시.
    private func consolePlan(_ buildingId: String, _ floorId: String) async throws -> ConsolePlanResponse {
        if let cached = planCache[floorId] { return cached }
        let base = ApiClient.defaultBaseURL.absoluteString
        let res: ConsolePlanResponse =
            try await consoleGet("\(base)/positioning/buildings/\(buildingId)/floor/\(floorId)/plan")
        planCache[floorId] = res
        return res
    }

    /// console 공통 GET (X-SDK-Key + snake_case 디코딩)
    private func consoleGet<R: Decodable>(_ urlString: String) async throws -> R {
        guard let url = URL(string: urlString) else { throw GsError.decode }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(keys.sdk, forHTTPHeaderField: "X-SDK-Key")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw GsError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1) }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(R.self, from: data)
    }
    /// 앵커 — GeoSpace 유일 잔존 (console 미제공, §10). TTL 3분 캐시로 층 재방문 시 즉시.
    private func getAnchors(_ floorId: String) async throws -> AnchorResponse {
        if let c = anchorCache[floorId], Date().timeIntervalSince(c.at) < 180 { return c.res }
        let res: AnchorResponse = try await get("api/m/floors/\(floorId)/anchors")
        anchorCache[floorId] = (Date(), res)
        return res
    }

    /// 존만 재조회 (존 등록 대기 폴링용) — plan 캐시 기준 미터 정규화까지 마쳐 반환.
    /// 층 로드 시 존이 0개였을 때, console 에서 영역이 생성되면 지도에 반영하기 위해 쓴다.
    /// ★ 던진다 — 통신 실패를 "존 0개"로 삼키면 새로고침이 지도의 존을 지워버린다(08-12).
    ///   단 404 는 예외: 서버가 존 없는 층에 빈 배열 대신 404 를 준다(08-12 실측) → 0개로 읽는다.
    func loadZones(buildingId: String, floorId: String) async throws -> [Zone] {
        let raw: [RawZone]
        do { raw = try await consoleZones(buildingId, floorId) }
        catch GsError.badResponse(404) { return [] }
        // 도면이 없으면(캐시에도 없으면) 미터로 그대로 — normalizeZones 가 같은 규칙을 쓴다.
        return normalizeZones(raw, image: planCache[floorId]?.plan?.image)
    }

    /// 존 폴리곤 미터 정규화 — console 이 아직 픽셀로 내려줌 (사양서 §6.4 는 미터).
    /// plan 의 scale(imgW/widthM)·imgH 로 변환하되, 값이 이미 미터 범위면 그대로 통과
    /// (서버가 미터화해도 코드 수정 없이 동작).
    ///
    /// ⚠️ `image` 가 nil = **도면이 없는 층**이면 폴리곤을 미터로 그대로 읽는다. 픽셀인지
    ///    미터인지를 가르는 기준이 도면 크기인데(아래 `isPixel`) 그 도면이 없기 때문이다.
    ///    안전한 전제다 — 픽셀 좌표는 도면 위에 찍어야 나오는 값이라, 찍을 도면이 없는
    ///    층의 존이 픽셀로 저장될 경로가 애초에 없다. loadZones 도 같은 규칙을 쓴다.
    private func normalizeZones(_ raw: [RawZone], image: PlanImage?) -> [Zone] {
        guard let image else { return raw.map(meterZone) }
        let widthM = image.widthM
        let heightM = widthM * Double(image.imgH) / Double(image.imgW)
        let scale = Double(image.imgW) / widthM
        let imgH = Double(image.imgH)
        let ox = image.originX, oy = image.originY
        return raw.map { z in
            let isPixel = z.polygon.contains { $0[0] > widthM * 1.5 || $0[1] > heightM * 1.5 }
            let pts = z.polygon.map { p -> Position in
                isPixel ? Position(x: p[0] / scale + ox, y: (imgH - p[1]) / scale + oy)
                        : Position(x: p[0], y: p[1])
            }
            return Zone(id: z.id, name: z.name, polygon: pts,
                        inDist: z.inDist, inCount: z.inCount,
                        inCountInterval: z.inCountInterval, outPeriod: z.outPeriod,
                        priority: z.priority, callInout: z.callInout,
                        dwellSeconds: z.dwellSeconds)
        }
    }

    /// 폴리곤을 미터로 그대로 읽는다 — 도면이 없어 픽셀/미터를 가릴 기준이 없을 때.
    private func meterZone(_ z: RawZone) -> Zone {
        Zone(id: z.id, name: z.name,
             polygon: z.polygon.map { Position(x: $0[0], y: $0[1]) },
             inDist: z.inDist, inCount: z.inCount,
             inCountInterval: z.inCountInterval, outPeriod: z.outPeriod,
             priority: z.priority, callInout: z.callInout,
             dwellSeconds: z.dwellSeconds)
    }

    /// 존 원시 데이터 (폴리곤 단위 미정 — normalizeZones 로 미터 정규화)
    struct RawZone {
        let id: String; let name: String; let polygon: [[Double]]
        // 판정 파라미터 — 콘솔 존 메타에서 보존 (기본값 = PRM 기본)
        var inDist: Double = 3.0; var inCount: Int = 0; var inCountInterval: Int = 0
        var outPeriod: Int = 0; var priority: Int = 1; var callInout: Bool = true
        var dwellSeconds: Int? = nil
    }

    /// zone — 콘솔(ock_) 단일 소스. 시책·이벤트가 콘솔 존 ID 기준으로 돌므로
    /// 판정 대상도 같은 곳에서 받아야 ID 가 어긋나지 않는다.
    /// (구 파트너 union 은 gpk_ 가 존 쓰기 권한까지 있어 클라이언트에서 제거 — 08-03)
    private func getZones(buildingId: String, _ floorId: String) async -> [RawZone] {
        (try? await consoleZones(buildingId, floorId)) ?? []
    }

    private func consoleZones(_ buildingId: String, _ floorId: String) async throws -> [RawZone] {
        let base = ApiClient.defaultBaseURL.absoluteString
        let res: ConsoleZonesResponse =
            try await consoleGet("\(base)/positioning/buildings/\(buildingId)/floor/\(floorId)/zones")
        var seen = Set<String>()
        return res.zones.compactMap { z in
            guard z.isActive, let poly = z.polygon, poly.count >= 3,
                  seen.insert(z.name).inserted else { return nil }
            return RawZone(id: z.zoneId, name: z.name, polygon: poly,
                           inDist: z.inDist ?? 3.0, inCount: z.inCount ?? 0,
                           inCountInterval: z.inCountInterval ?? 0, outPeriod: z.outPeriod ?? 0,
                           priority: z.priority ?? 1, callInout: z.callInout ?? true,
                           dwellSeconds: z.dwellSeconds)
        }
    }


    // MARK: - HTTP

    private func get<R: Decodable>(_ path: String) async throws -> R {
        try await request(path, header: "X-SDK-Key", value: keys.geospace)
    }
    private func request<R: Decodable>(_ path: String, header: String, value: String) async throws -> R {
        var req = URLRequest(url: URL(string: "https://\(host)/\(path)")!, timeoutInterval: 20)
        req.setValue(value, forHTTPHeaderField: header)
        req.setValue("close", forHTTPHeaderField: "Connection")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GsError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw GsError.badResponse(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(R.self, from: data) else { throw GsError.decode }
        return decoded
    }

    // MARK: - DTO

    private typealias BuildingsResponse = GeospaceBuildingsResponse

    /// GeoSpace 직행 응답. 도면이 **있는** 층에서만 디코드된다 — 없는 층은
    /// planImageIfAny 가 콘솔 단계에서 이미 nil 로 끝낸다.
    private struct PlanResponse: Decodable {
        let plan: PlanBody
        var image: PlanImage { plan.image }
        struct PlanBody: Decodable { let image: PlanImage }
    }

    /// console §6.4b 응답 (snake_case → convertFromSnakeCase 디코딩이라 PlanImage 그대로 맞음)
    private struct ConsolePlanResponse: Decodable {
        let hasPlan: Bool
        let floorName: String?
        let plan: Body?
        struct Body: Decodable { let image: PlanImage }
    }

    /// console §6.4 zones 응답 (snake_case)
    private struct ConsoleZonesResponse: Decodable {
        let zones: [Zone]
        struct Zone: Decodable {
            let zoneId: String
            let name: String
            let polygon: [[Double]]?
            let isActive: Bool
            // 판정 파라미터 (§6.4 존 메타) — PRM 엔진이 소비. 구서버 호환 위해 옵셔널
            let inDist: Double?
            let inCount: Int?
            let inCountInterval: Int?
            let outPeriod: Int?
            let priority: Int?
            let callInout: Bool?
            let dwellSeconds: Int?
        }
    }

    /// console §6.2 buildings / §6.3 floors 응답 (snake_case)
    private struct ConsoleBuildingsResponse: Decodable {
        let buildings: [B]
        struct B: Decodable {
            let buildingId: String
            let name: String
            let floorCount: Int?     // 서버 floor_count (TBD — 실릴 때까지 nil)
        }
    }
    private struct ConsoleFloorsResponse: Decodable {
        let floors: [F]
        /// name·hasPlan 은 콘솔 배포 시차를 고려해 옵셔널로 둔다 — 없던 시절 응답에도 깨지지 않는다.
        struct F: Decodable {
            let floorId: String
            let name: String?
            let hasPlan: Bool?
        }
    }
    private struct PlanImage: Decodable {
        let dataUrl: String
        let widthM: Double
        let imgW: Int
        let imgH: Int
        let originX: Double
        let originY: Double
        func pngData() -> Data? {
            let b64 = dataUrl.contains(",") ? String(dataUrl.split(separator: ",", maxSplits: 1)[1]) : dataUrl
            guard let data = Data(base64Encoded: b64) else { return nil }
            return data
        }
    }

    private struct AnchorResponse: Decodable { let anchors: [AnchorDTO] }
    private struct AnchorDTO: Decodable {
        let uwbMac: String?
        let x: Double?
        let y: Double?
        let sessionId: Int?          // = networkIdentifier (층별 UWB 세션)
        let clusterStatus: String?   // "auto_done"=배치완료 / "apply_failed" 등=미배치
        /// 주소 = UWB MAC 뒤 2바이트 (마지막 4 hex)
        func toLocator() -> Locator? {
            guard let mac = uwbMac, let x, let y,
                  let addr = Int(String(mac.suffix(4)), radix: 16) else { return nil }
            // 서버가 값을 안 주면(옛 응답) 배치된 것으로 본다 — 모르는 것을 고장으로
            // 쳐서 멀쩡한 로케이터를 지도에서 죽은 것처럼 보이게 하지 않는다.
            return Locator(address: addr & 0xFFFF, x: x, y: y, z: 0,
                           isPlaced: clusterStatus.map { $0 == "auto_done" } ?? true)
        }
    }

    /// 파트너 zones 응답 = 최상위 배열. 폴리곤은 미터(0~13). (판정 파라미터 다수 있으나 지도엔 name/폴리곤만)
    private struct ZoneDTO: Decodable {
        let id: String          // zone_id (console 다운링크 큐와 동일 UUID)
        let name: String
        let isActive: Bool
        let polygon: [[Double]]?
    }
}

