//
//  StubURLProtocol.swift
//  네트워크 대역 — 요청을 가로채 canned 응답 반환 + 요청 이력 기록 (실서버 0회)
//

import Foundation

final class StubURLProtocol: URLProtocol {

    /// 테스트가 세팅: 요청 → (상태코드, 응답바디). 경로별 라우팅은 이 클로저 안에서.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    /// 검증용 이력
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var requests: [(path: String, method: String, body: Data?)] = []

    static func reset() {
        handler = nil; lastRequest = nil; lastBody = nil; requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            // URLSession은 POST 바디를 stream으로 넘김 → 읽어서 복원
            stream.open(); defer { stream.close() }
            var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 1024)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }
        Self.lastRequest = request
        Self.lastBody = body
        Self.requests.append((request.url?.path ?? "", request.httpMethod ?? "", body))

        let (status, resBody) = Self.handler?(request) ?? (200, Data("{}".utf8))
        let res = HTTPURLResponse(url: request.url!, statusCode: status,
                                  httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 스텁 세션 팩토리 (테스트 공용)
func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}
