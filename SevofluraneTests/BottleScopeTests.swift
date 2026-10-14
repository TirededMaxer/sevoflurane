import Foundation
import Testing
@testable import Sevoflurane

/// Which processes count as the bottle's: the ones with a file inside its
/// directory, and none of another bottle's.
struct BottleScopeTests {
    private static let root = "/Users/me/Library/Application Support/Sevoflurane/Bottles/Steam"

    @Test
    func `a file inside the bottle or the bottle itself counts`() {
        #expect(ClientLifecycle.isInBottle(openPaths: [Self.root], roots: [Self.root]))
        #expect(ClientLifecycle.isInBottle(
            openPaths: ["/dev/null", Self.root + "/drive_c/windows/system32"], roots: [Self.root],
        ))
    }

    @Test
    func `CrossOver's own Steam bottle is another bottle`() {
        let crossOver = "/Users/me/Library/Application Support/CrossOver/Bottles/Steam/drive_c/steam.exe"
        #expect(!ClientLifecycle.isInBottle(openPaths: [crossOver], roots: [Self.root]))
    }

    @Test
    func `a sibling whose name begins with the bottle's is another bottle`() {
        let sibling = "/Users/me/Library/Application Support/Sevoflurane/Bottles/Steam2/drive_c"
        let older = "/Users/me/Library/Application Support/Sevoflurane/Bottles/SteamOld/system.reg"
        #expect(!ClientLifecycle.isInBottle(openPaths: [sibling, older], roots: [Self.root]))
    }

    @Test
    func `a quote in the bottle's name is only a character`() {
        let root = "/Users/me/Bottles/Someone's Steam"
        #expect(ClientLifecycle.isInBottle(openPaths: [root + "/user.reg"], roots: [root]))
        #expect(!ClientLifecycle.isInBottle(openPaths: ["/Users/me/Bottles/Someone"], roots: [root]))
    }

    @Test
    func `a process's open files are read from the kernel, this one's among them`() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "bottle-scope-\(UUID().uuidString).txt")
        try Data("open".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // The kernel reports `/private/var/…` where Foundation says `/var/…`,
        // so the match is on the file's unique name.
        let paths = WineOrphans.openFilePaths(of: getpid())
        #expect(paths.contains { $0.hasSuffix("/" + file.lastPathComponent) })
    }
}
