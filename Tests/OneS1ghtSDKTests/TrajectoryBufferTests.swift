//
//  TrajectoryBufferTests.swift
//  좌표 버퍼 — 상한 분할 전송 · 실패 시 유지
//

import XCTest
@testable import OneS1ghtSDK

@MainActor
final class TrajectoryBufferTests: XCTestCase {

    private func point(_ i: Int) -> PositionPoint {
        PositionPoint(floor_id: "F", coordinates: Coordinates(x: Double(i), y: 0, z: 0),
                      captured_at: "t\(i)")
    }

    // maxPerRequest 단위로 잘라 여러 번 전송 (5개, 상한2 → 2+2+1)
    func testFlush_chunksByMaxPerRequest() async {
        var batches: [[PositionPoint]] = []
        let buffer = TrajectoryBuffer(maxPerRequest: 2) { batch in
            batches.append(batch); return true
        }
        (1...5).forEach { buffer.add(point($0)) }
        await buffer.flush()

        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
        XCTAssertEqual(buffer.count, 0)
    }

    // 전송 실패 시 남은 건 유지 (첫 배치 성공, 둘째 실패 → 3개 남음)
    func testFlush_keepsRemainderOnFailure() async {
        var calls = 0
        let buffer = TrajectoryBuffer(maxPerRequest: 2) { _ in
            calls += 1; return calls == 1          // 첫 번째만 성공
        }
        (1...5).forEach { buffer.add(point($0)) }
        await buffer.flush()

        XCTAssertEqual(buffer.count, 3)            // 2개만 제거, 3개 유지
        // 다음 flush에 재시도 가능
        await buffer.flush()                       // calls 2,3... 이번엔 실패 → 그대로
        XCTAssertEqual(buffer.count, 3)
    }
}
