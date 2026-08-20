//
//  GeospaceClient.swift
//  OneS1ghtSDK
//
//  ⚠️ SDK 내부 전용 — 호스트 앱은 이 타입을 모른다.
//     고객사는 initialize(apiKey:geospaceKey:) 로 키 2개만 넘기고,
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
    init(keys: Keys) { self.keys = keys }

    private let host = "geospace.geoplan.io"

    // 공개 타입(SpaceBuilding/SpaceFloor/AnchorPoint/FloorInfra)은 Models/SpaceModels.swift.
    // 존은 SDK 공통 타입(Zone/Position)을 그대로 쓴다 — ZoneEngine 에 변환 없이 주입된다.

    private(set) var status: String = SdkLocalized.text("gs.idle")

    // TLS 검증은 표준 그대로 — SDK 는 인증서 우회를 하지 않는다 (ApiClient 와 동일 원칙)
    private let session = URLSession.shared

    enum GsError: Error { case badResponse(Int), noImage, decode }

    // MARK: - 공개 진입점

    /// 빌딩/층 트리 로드 (선택 UI용) — 콘솔(ock_)이 기본, 실패 시 GeoSpace 폴백.
    /// 콘솔 층은 존에서 파생돼 존이 0개면 빈 목록이 되는 구조(08-03)라, 그 경우에만
    /// 층을 독립 제공하는 GeoSpace 모바일 API 로 내려간다. (08-05 순서 교체 — 콘솔이 단일 진실)
    func loadBuildings() async throws -> [SpaceBuilding] {
        do { return try await consoleBuildings() }
        catch { return try await mobileBuildings() }
    }

    private func consoleBuildings() async throws -> [SpaceBuilding] {
        let base = ApiClient.defaultBaseURL.absoluteString
        let list: ConsoleBuildingsResponse = try await consoleGet("\(base)/positioning/buildings")
        var out: [SpaceBuilding] = []
        var gsCache: [SpaceBuilding]?                                     // 층 우회용 (필요할 때 1회만)
        for b in list.buildings where !b.buildingId.hasPrefix("sim-") {   // GeoSpace 미연동 sim 매장 제외
            let fl: ConsoleFloorsResponse = try await consoleGet("\(base)/positioning/buildings/\(b.buildingId)/floors")
            var floorIds = fl.floors.map(\.floorId)
            // 콘솔 층은 존에서 파생돼, 존 미등록 층은 목록에 안 잡힌다(서버 구조).
            // 도면·앵커가 있어도 층 ID 를 못 얻어 측위 진입이 막히므로 GeoSpace 로 층만 우회한다.
            // (도면·존은 그대로 콘솔 프록시 사용 — 서버가 층을 독립 제공하면 이 블록은 자동으로 안 탄다)
            if floorIds.isEmpty {
                if gsCache == nil { gsCache = try? await mobileBuildings() }
                floorIds = gsCache?.first { $0.id == b.buildingId }?.floors.map(\.id) ?? []
            }
            var floors: [SpaceFloor] = []
            for id in floorIds {
                let plan = try? await consolePlan(b.buildingId, id)        // 이름 획득 + 도면 선로딩 캐시
                floors.append(SpaceFloor(id: id,
                                    name: plan?.floorName ?? String(id.prefix(8)),
                                    hasPlan: plan?.hasPlan ?? false))
            }
            out.append(SpaceBuilding(id: b.buildingId, name: b.name, floors: floors))
        }
        guard !out.isEmpty else { throw GsError.decode }
        return out
    }

    private func mobileBuildings() async throws -> [SpaceBuilding] {
        let res: BuildingsResponse = try await get("api/m/buildings")
        return res.buildings.map { b in
            SpaceBuilding(id: b.buildingId, name: b.buildingName,
                     floors: b.floors.map { SpaceFloor(id: $0.floorId, name: $0.floorName, hasPlan: $0.hasPlan) })
        }
    }

    /// 선택한 building/floor의 도면·앵커·존 로드
    func loadInfra(buildingId: String, floorId: String) async throws -> FloorInfra {
        status = SdkLocalized.text("gs.loading")
        async let planTask = getPlan(buildingId: buildingId, floorId)
        async let anchorTask = getAnchors(floorId)
        async let zoneTask = getZones(buildingId: buildingId, floorId)
        let (plan, anchorRes) = try await (planTask, anchorTask)
        let zonesRaw = await zoneTask

        guard let imageData = plan.image.pngData() else { throw GsError.noImage }
        let widthM = plan.image.widthM
        let heightM = widthM * Double(plan.image.imgH) / Double(plan.image.imgW)
        let ox = plan.image.originX, oy = plan.image.originY

        let zones = normalizeZones(zonesRaw, image: plan.image)

        // 측위 가능 판정 = 앵커 + 세션ID 존재. clusterStatus 는 안 따진다 —
        // (등록 절차 상태일 뿐, 실제 통신 여부는 시작 후 수신 watchdog 이 판정)
        let ready = !anchorRes.anchors.isEmpty
            && anchorRes.anchors.first?.sessionId != nil
        let infra = FloorInfra(
            buildingId: buildingId,
            floorId: floorId,
            sessionId: anchorRes.anchors.first?.sessionId,
            positioningReady: ready,
            plan: FloorPlanImage(pngData: imageData, originX: ox, originY: oy,
                                 widthM: widthM, heightM: heightM),
            anchors: anchorRes.anchors.compactMap { $0.toAnchor() },
            zones: zones
        )
        status = SdkLocalized.format("gs.done", infra.anchors.count, zones.count)
        return infra
    }

    // MARK: - 엔드포인트

    // 세션 캐시 — plan 은 정적(층이름 겸 선로딩), 앵커는 전원상태(clusterStatus)가 변할 수 있어 TTL
    private var planCache: [String: ConsolePlanResponse] = [:]                 // floorId → plan
    private var anchorCache: [String: (at: Date, res: AnchorResponse)] = [:]   // floorId → 앵커 (TTL 3분)

    /// 도면 — console 프록시(§6.4b) 우선(+세션 캐시), 실패 시 GeoSpace 직행 폴백.
    private func getPlan(buildingId: String, _ floorId: String) async throws -> PlanResponse {
        if let res = try? await consolePlan(buildingId, floorId),
           res.hasPlan, let body = res.plan {
            return PlanResponse(plan: .init(image: body.image))
        }
        return try await get("api/m/floors/\(floorId)/plan")
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
        guard let image = planCache[floorId]?.plan?.image else {
            return raw.map { z in Zone(id: z.id, name: z.name,
                                       polygon: z.polygon.map { Position(x: $0[0], y: $0[1]) },
                                       inDist: z.inDist, inCount: z.inCount,
                                       inCountInterval: z.inCountInterval, outPeriod: z.outPeriod,
                                       priority: z.priority, callInout: z.callInout,
                                       dwellSeconds: z.dwellSeconds) }
        }
        return normalizeZones(raw, image: image)
    }

    /// 존 폴리곤 미터 정규화 — console 이 아직 픽셀로 내려줌 (사양서 §6.4 는 미터).
    /// plan 의 scale(imgW/widthM)·imgH 로 변환하되, 값이 이미 미터 범위면 그대로 통과
    /// (서버가 미터화해도 코드 수정 없이 동작).
    private func normalizeZones(_ raw: [RawZone], image: PlanImage) -> [Zone] {
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

    private struct BuildingsResponse: Decodable {
        let buildings: [BuildingDTO]
        struct BuildingDTO: Decodable {
            let buildingId: String
            let buildingName: String
            let floors: [FloorDTO]
        }
        struct FloorDTO: Decodable {
            let floorId: String
            let floorName: String
            let hasPlan: Bool
        }
    }

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
        struct B: Decodable { let buildingId: String; let name: String }
    }
    private struct ConsoleFloorsResponse: Decodable {
        let floors: [F]
        struct F: Decodable { let floorId: String }
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
        func toAnchor() -> AnchorPoint? {
            guard let mac = uwbMac, let x, let y,
                  let addr = Int(String(mac.suffix(4)), radix: 16) else { return nil }
            return AnchorPoint(address: addr & 0xFFFF, x: x, y: y, z: 0)
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

