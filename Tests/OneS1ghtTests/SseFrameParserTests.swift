import XCTest
@testable import OneS1ght

/// SSE 프레임 파서 — 청크가 프레임 경계와 무관하게 잘려 들어와도 복원해야 한다.
final class SseFrameParserTests: XCTestCase {

    func testParsesOneCompleteFrame() {
        var p = SseFrameParser()
        let frames = p.feed("event: zones.changed\ndata: {\"seq\":3}\n\n")

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, "zones.changed")
        XCTAssertEqual(frames[0].data, "{\"seq\":3}")
    }

    func testRebuildsAFrameSplitAcrossChunks() {
        var p = SseFrameParser()
        XCTAssertTrue(p.feed("event: zones.cha").isEmpty)
        XCTAssertTrue(p.feed("nged\ndata: {\"seq\":3}").isEmpty)

        let frames = p.feed("\n\n")

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, "zones.changed")
    }

    func testHeartbeatCommentProducesNoFrame() {
        var p = SseFrameParser()

        XCTAssertTrue(p.feed(": ping\n\n").isEmpty)
    }

    func testMultiLineDataIsJoinedWithNewline() {
        var p = SseFrameParser()
        let frames = p.feed("event: x\ndata: a\ndata: b\n\n")

        XCTAssertEqual(frames[0].data, "a\nb")
    }

    func testFrameWithoutEventNameDefaultsToMessage() {
        var p = SseFrameParser()
        let frames = p.feed("data: {}\n\n")

        XCTAssertEqual(frames[0].event, "message")
    }

    func testTwoFramesInOneChunk() {
        var p = SseFrameParser()
        let frames = p.feed("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n")

        XCTAssertEqual(frames.map(\.event), ["a", "b"])
    }
}
