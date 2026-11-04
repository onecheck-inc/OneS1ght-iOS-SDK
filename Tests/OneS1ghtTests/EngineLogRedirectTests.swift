import XCTest
@testable import OneS1ght

final class EngineLogRedirectTests: XCTestCase {

    private let fm = FileManager.default
    private var container: URL!
    private var documents: URL { container.appendingPathComponent("Documents") }

    override func setUpWithError() throws {
        container = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: container)
    }

    private func write(_ name: String, under folder: URL) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    private func holder(_ module: String) -> URL {
        container.appendingPathComponent("tmp/\(EngineLogRedirect.holderFolder)/\(module)")
    }

    func testLinksEveryModuleWithRelativePath() throws {
        EngineLogRedirect.apply(documents: documents)
        for module in EngineLogRedirect.moduleFolders {
            let destination = try fm.destinationOfSymbolicLink(
                atPath: documents.appendingPathComponent(module).path)
            XCTAssertEqual(destination, "../tmp/\(EngineLogRedirect.holderFolder)/\(module)")
        }
    }

    func testWritesThroughLinkLandInTmp() throws {
        EngineLogRedirect.apply(documents: documents)
        try write("20261104.txt", under: documents.appendingPathComponent("gpi-ihub"))
        XCTAssertTrue(fm.fileExists(atPath: holder("gpi-ihub").appendingPathComponent("20261104.txt").path))
    }

    func testRemovesRealFolderLeftByOlderVersion() throws {
        let old = documents.appendingPathComponent("gpi-ihub")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try write("20261001.txt", under: old)

        EngineLogRedirect.apply(documents: documents)

        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: old.path))
        XCTAssertFalse(fm.fileExists(atPath: old.appendingPathComponent("20261001.txt").path))
    }

    func testRepeatedApplyClearsLogsButKeepsFolder() throws {
        EngineLogRedirect.apply(documents: documents)
        try write("20261104.txt", under: holder("gpi-dltdoa"))

        EngineLogRedirect.apply(documents: documents)

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: holder("gpi-dltdoa").path), [])
    }

    func testRebuildsTargetWhenTmpWasPurged() throws {
        EngineLogRedirect.apply(documents: documents)
        try fm.removeItem(at: container.appendingPathComponent("tmp"))

        EngineLogRedirect.apply(documents: documents)

        try write("20261104.txt", under: documents.appendingPathComponent("gpi-prm"))
        XCTAssertTrue(fm.fileExists(atPath: holder("gpi-prm").appendingPathComponent("20261104.txt").path))
    }

    func testLeavesOtherDocumentsAlone() throws {
        try write("customer.txt", under: documents)
        EngineLogRedirect.apply(documents: documents)
        XCTAssertTrue(fm.fileExists(atPath: documents.appendingPathComponent("customer.txt").path))
    }
}
