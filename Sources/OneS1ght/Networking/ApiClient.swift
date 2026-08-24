//
//  ApiClient.swift
//  서버 통신 — URLSession 경량 클라이언트 (사양서 §6 엔드포인트 5종)
//
//  · 모든 요청: X-SDK-Key 헤더 + JSON. JWT/토큰 교환 없음 (사양서 §2)
//  · 상태코드 → 타입화 에러 (에러 본문 {detail} 파싱)
//  · HTTPS + TLS 검증 그대로 (우회 금지). ⚠️ 키는 로그·에러 메시지에 노출하지 않는다
//

import Foundation

/// 서버 응답 상태코드의 타입화 매핑 (사양서 §9)
public enum ApiError: Error, Equatable {
    case invalidKey(detail: String?)         // 401 — 키 무효/폐기 → 측위 중단 (재시도 무의미)
    case forbidden(detail: String?)          // 403 — 다른 테넌트 자원
    case notFound(detail: String?)           // 404 — (floors) 층에 존 없음 = 정상 분기
    case unprocessable(detail: String?)      // 422 — 페이로드 문제 (개발 버그)
    case server(status: Int, detail: String?) // 5xx 등 그 외
    case network(URLError)                   // 오프라인·타임아웃 등 전송 실패
    /// 응답 JSON 형태 불일치. `detail` 에 **무엇을 못 읽었는지** 담는다 —
    /// 이게 없으면 화면에 "decoding" 넉 자만 떠서 어느 응답의 어느 필드인지 알 길이 없다.
    case decoding(detail: String?)
}

extension ApiError: CustomStringConvertible {
    /// 앱이 `\(error)` 로 화면에 그대로 찍는다 — 개발자가 보고 바로 움직일 수 있어야 한다.
    /// ⚠️ 키·좌표 같은 값은 담지 않는다. 담는 것은 "무엇이" 잘못됐는지까지다.
    public var description: String {
        switch self {
        case .invalidKey(let d):     return "SDK 키가 무효하거나 폐기됨" + Self.suffix(d)
        case .forbidden(let d):      return "접근 권한 없음 (다른 고객사 자원)" + Self.suffix(d)
        case .notFound(let d):       return "대상을 찾을 수 없음" + Self.suffix(d)
        case .unprocessable(let d):  return "서버가 요청을 거절함" + Self.suffix(d)
        case .server(let s, let d):  return "서버 오류 (HTTP \(s))" + Self.suffix(d)
        case .network(let e):        return "네트워크 실패 (\(e.code.rawValue))"
        case .decoding(let d):       return "응답 해석 실패" + Self.suffix(d)
        }
    }

    private static func suffix(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return " — " + detail
    }
}

/// 에러 본문 { "detail": "..." }
private struct ErrorBody: Decodable { let detail: String? }

public final class ApiClient {

    public static let defaultBaseURL = URL(string: "https://console.ones1ght.com/api/sdk/v1")!

    // 같은 모듈의 LiveConfigStream 이 스트림 요청을 만들 때 쓴다.
    // ⚠️ internal 까지만 — public 으로 올리면 SDK 키가 고객사 코드에 노출된다.
    let apiKey: String
    let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval = 10

    /// - Parameters:
    ///   - apiKey: `<SDK 키>` (헤더에만 실림 — 저장·로그 금지)
    ///   - baseURL: 환경별 교체 가능 (기본 prod)
    ///   - session: 테스트에서 URLProtocol 스텁 세션 주입
    public init(apiKey: String,
                baseURL: URL = ApiClient.defaultBaseURL,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - 엔드포인트 5종 (사양서 §6)

    /// ① POST /auth/verify — 키 검증 + 클라 등록 (초기화 1회)
    public func verify(_ req: ReqVerify) async throws -> ResVerify {
        try await post("/auth/verify", body: req)
    }

    /// ② GET /positioning/buildings — 건물·층 목록 (측위 활성화 시 1회)
    public func buildings() async throws -> ResBuildings {
        try await get("/positioning/buildings")
    }

    /// ③ GET /positioning/floors/{floor_id} — 층 존 설정 (층 진입 시 해당 층만)
    public func floorConfig(floorId: String) async throws -> ResFloorConfig {
        try await get("/positioning/floors/\(floorId)")
    }

    /// ④ POST /events/zone — 존 입장/체류/퇴장 (판정 즉시)
    public func sendZoneEvent(_ req: ReqZoneEvent) async throws -> ResZoneEvent {
        try await post("/events/zone", body: req)
    }

    /// ⑤ POST /positioning/logs — 동선 좌표 벌크 (300건/60초/종료)
    public func sendPositionLogs(_ req: ReqPositionBulk) async throws -> ResPositionBulk {
        try await post("/positioning/logs", body: req)
    }

    // MARK: - 프로필 (서버 TBD)

    /// ⑥ POST /profiles — 프로필 생성, 서버가 profile_id 발급
    public func createProfile(_ req: ReqProfile) async throws -> ResProfileCreate {
        try await post("/profiles", body: req)
    }

    /// ⑦ GET /profiles/{id}
    public func getProfile(_ profileId: String) async throws -> ResProfile {
        try await get("/profiles/\(profileId)")
    }

    /// ⑧ PUT /profiles/{id} — 속성 전체 교체
    public func putProfile(_ profileId: String, _ req: ReqProfile) async throws -> ResProfile {
        try await send("/profiles/\(profileId)", method: "PUT", body: req)
    }

    /// ⑨ DELETE /profiles/{id}
    public func deleteProfile(_ profileId: String) async throws -> ResProfileDelete {
        try await send("/profiles/\(profileId)", method: "DELETE", body: Optional<ReqProfile>.none)
    }

    // MARK: - SDK 로그

    /// ⑩ POST /logs — 관리자가 콘솔 로그 분석기에서 볼 줄을 적재한다.
    /// 서버가 느슨하게 받도록 설계돼 있어(레벨 정규화·2000자 절단·시각 결측 보정)
    /// 실패해도 앱 동작에는 영향이 없다.
    public func sendLogs(_ req: ReqSdkLogs) async throws -> ResSdkLogs {
        try await post("/logs", body: req)
    }

    // MARK: - 내부 공통

    private func get<R: Decodable>(_ path: String) async throws -> R {
        try await perform(request(path: path, method: "GET", body: nil))
    }

    private func send<B: Encodable, R: Decodable>(_ path: String, method: String, body: B?) async throws -> R {
        let data = try body.map { try JSONEncoder().encode($0) }
        return try await perform(request(path: path, method: method, body: data))
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        let data = try JSONEncoder().encode(body)
        return try await perform(request(path: path, method: "POST", body: data))
    }

    private func request(path: String, method: String, body: Data?) -> URLRequest {
        // baseURL 뒤에 path 문자열 결합 (appendingPathComponent는 "/" 인코딩 이슈가 있어 문자열로)
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!,
                             timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-SDK-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    private func perform<R: Decodable>(_ req: URLRequest) async throws -> R {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            throw ApiError.network(e)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ApiError.decoding(detail: "HTTP 응답이 아님")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(R.self, from: data)
            } catch {
                throw ApiError.decoding(detail: Self.describe(error, as: R.self))
            }
        case 401: throw ApiError.invalidKey(detail: detail(data))
        case 403: throw ApiError.forbidden(detail: detail(data))
        case 404: throw ApiError.notFound(detail: detail(data))
        case 422: throw ApiError.unprocessable(detail: detail(data))
        default:  throw ApiError.server(status: http.statusCode, detail: detail(data))
        }
    }

    /// 에러 본문에서 detail 추출 (형태 다르면 nil — 실패해도 에러 매핑은 유지)
    private func detail(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
    }

    /// 디코드 실패를 사람이 읽을 한 줄로. ⚠️ 값은 넣지 않는다 — 응답에 개인정보가 섞일 수 있다.
    private static func describe<R>(_ error: Error, as type: R.Type) -> String {
        let what = String(describing: type)
        guard let e = error as? DecodingError else { return "\(what): \(error)" }
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            let at = path(ctx)
            return "\(what): 필드 누락 \(at.isEmpty ? key.stringValue : at + "." + key.stringValue)"
        case .typeMismatch(let expected, let ctx):
            return "\(what): \(path(ctx)) 의 타입이 다름 (기대 \(expected))"
        case .valueNotFound(let expected, let ctx):
            return "\(what): \(path(ctx)) 가 null (기대 \(expected))"
        case .dataCorrupted(let ctx):
            let at = path(ctx)
            return "\(what): JSON 이 깨짐\(at.isEmpty ? "" : " (\(at))")"
        @unknown default:
            return "\(what): 디코드 실패"
        }
    }
}
