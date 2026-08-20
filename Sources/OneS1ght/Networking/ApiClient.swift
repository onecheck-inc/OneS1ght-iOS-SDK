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
    case decoding                            // 응답 JSON 형태 불일치
}

/// 에러 본문 { "detail": "..." }
private struct ErrorBody: Decodable { let detail: String? }

public final class ApiClient {

    public static let defaultBaseURL = URL(string: "https://console.ones1ght.com/api/sdk/v1")!

    private let apiKey: String
    private let baseURL: URL
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
        guard let http = response as? HTTPURLResponse else { throw ApiError.decoding }

        switch http.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(R.self, from: data) else {
                throw ApiError.decoding
            }
            return decoded
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
}
