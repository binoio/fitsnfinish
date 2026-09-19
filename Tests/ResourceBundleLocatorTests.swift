import XCTest
@testable import FitsnFinishCore

final class ResourceBundleLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(in directory: URL, named name: String) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("shader".utf8).write(to: bundle.appendingPathComponent("SubtractEngine.metal"))
        return bundle
    }

    func testReturnsNilWhenNoCandidateExists() {
        let missing = root.appendingPathComponent("nowhere", isDirectory: true)
        XCTAssertNil(ResourceBundleLocator.url(named: "Pkg_Target", in: [missing, root]))
    }

    func testFindsBundleInFirstMatchingDirectory() throws {
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let expected = try makeBundle(in: resources, named: "Pkg_Target")
        let found = ResourceBundleLocator.url(
            named: "Pkg_Target",
            in: [root.appendingPathComponent("elsewhere"), resources, root]
        )
        XCTAssertEqual(found?.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testSearchOrderPrefersEarlierDirectories() throws {
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        let expected = try makeBundle(in: first, named: "Pkg_Target")
        _ = try makeBundle(in: second, named: "Pkg_Target")
        let found = ResourceBundleLocator.url(named: "Pkg_Target", in: [second, first])
        XCTAssertEqual(found?.standardizedFileURL.path,
                       second.appendingPathComponent("Pkg_Target.bundle").standardizedFileURL.path)
        XCTAssertNotEqual(found?.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testIgnoresPlainFileWithBundleName() throws {
        try Data().write(to: root.appendingPathComponent("Pkg_Target.bundle"))
        XCTAssertNil(ResourceBundleLocator.url(named: "Pkg_Target", in: [root]))
    }

    func testBundleExposesResourcesWithoutInfoPlist() throws {
        // `swift build` bundles ship no Info.plist; resources must still resolve.
        _ = try makeBundle(in: root, named: "Pkg_Target")
        let url = try XCTUnwrap(ResourceBundleLocator.url(named: "Pkg_Target", in: [root]))
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertNotNil(bundle.url(forResource: "SubtractEngine", withExtension: "metal"))
    }

    func testDefaultSearchDirectoriesStartWithResourcesAndNeverContainBuildPaths() {
        let directories = ResourceBundleLocator.defaultSearchDirectories()
        XCTAssertFalse(directories.isEmpty)
        for directory in directories {
            XCTAssertFalse(directory.path.contains("/Downloads/"), "\(directory.path)")
        }
        if let resources = Bundle.main.resourceURL {
            XCTAssertEqual(directories.first?.path, resources.path)
        }
    }
}
