import Foundation
import XCTest

/// Test helpers: locate the package root and manage temp directories.
extension XCTestCase {

    /// Walks up from this source file to the directory containing Package.swift.
    var packageRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    var fixturesDir: URL {
        packageRoot.appendingPathComponent("Tests/SaybookTests/Fixtures")
    }

    @discardableResult
    func makeTempDir() throws -> URL {
        let url = URL.temporaryDirectory
            .appendingPathComponent("saybook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Runs `/usr/bin/zip -r <archive> <paths...>` inside `cwd`.
    func zip(paths: [URL], into archive: URL, cwd: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-X", "-r", "-q", archive.path] + paths.map(\.lastPathComponent)
        task.currentDirectoryURL = cwd
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "zip failed: \(archive.path)")
    }
}
