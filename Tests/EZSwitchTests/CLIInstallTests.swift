import Foundation
import Testing
@testable import EZSwitch

@Suite("CLI install")
struct CLIInstallTests {
    private struct Fixture {
        let root: URL
        let bin: URL
        let appCLI: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIInstallTests-\(UUID().uuidString)")
            bin = root.appendingPathComponent("bin", isDirectory: true)
            appCLI = root.appendingPathComponent("EZSwitch.app/Contents/MacOS/ezs")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: appCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: appCLI)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appCLI.path)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        var installer: CLIInstaller { CLIInstaller(destinationDirectory: bin, linkName: "ezs") }
        var link: URL { bin.appendingPathComponent("ezs") }
    }

    @Test func absentDestinationIsNotInstalled() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(fixture.installer.status(expectedTarget: fixture.appCLI) == .notInstalled)
        #expect(fixture.installer.plan(expectedTarget: fixture.appCLI) == .createLink)
    }

    @Test func installCreatesMatchingSymlinkAndIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.installer.installUnprivileged(expectedTarget: fixture.appCLI)
        #expect(fixture.installer.status(expectedTarget: fixture.appCLI)
            == .installed(linkTarget: fixture.appCLI.standardizedFileURL.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path) == fixture.appCLI.path)
        try fixture.installer.installUnprivileged(expectedTarget: fixture.appCLI) // no-op success
        #expect(fixture.installer.plan(expectedTarget: fixture.appCLI) == .alreadyInstalled)
    }

    @Test func createsMissingDestinationDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let nested = fixture.root.appendingPathComponent("nested/deep/bin", isDirectory: true)
        let installer = CLIInstaller(destinationDirectory: nested, linkName: "ezs")
        try installer.installUnprivileged(expectedTarget: fixture.appCLI)
        #expect(installer.status(expectedTarget: fixture.appCLI)
            == .installed(linkTarget: fixture.appCLI.standardizedFileURL.path))
    }

    @Test func refusesUnrelatedSymlinkWithoutTouchingIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let other = fixture.root.appendingPathComponent("other-ezs")
        try Data("x".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: other)
        guard case .conflict(let reason) = fixture.installer.status(expectedTarget: fixture.appCLI) else {
            Issue.record("expected conflict"); return
        }
        #expect(reason.contains("其他"))
        #expect(throws: CLIInstallError.self) { try fixture.installer.installUnprivileged(expectedTarget: fixture.appCLI) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path) == other.path)
    }

    @Test func refusesExistingRegularFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("keep me".utf8).write(to: fixture.link)
        guard case .conflict(let reason) = fixture.installer.status(expectedTarget: fixture.appCLI) else {
            Issue.record("expected conflict"); return
        }
        #expect(reason.contains("普通文件"))
        #expect(throws: CLIInstallError.self) { try fixture.installer.installUnprivileged(expectedTarget: fixture.appCLI) }
        #expect(try Data(contentsOf: fixture.link) == Data("keep me".utf8))
    }

    @Test func refusesExistingDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.link, withIntermediateDirectories: true)
        guard case .conflict(let reason) = fixture.installer.status(expectedTarget: fixture.appCLI) else {
            Issue.record("expected conflict"); return
        }
        #expect(reason.contains("目录"))
        #expect(throws: CLIInstallError.self) { try fixture.installer.installUnprivileged(expectedTarget: fixture.appCLI) }
    }

    @Test func relativeMatchingSymlinkCountsAsInstalled() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let manual = fixture.root.appendingPathComponent("manual-ezs")
        try Data("x".utf8).write(to: manual)
        try FileManager.default.createSymbolicLink(atPath: fixture.link.path, withDestinationPath: "../manual-ezs")
        #expect(fixture.installer.status(expectedTarget: manual) == .installed(linkTarget: manual.standardizedFileURL.path))
    }

    @Test func generatedCommandCreatesLinkWhenAbsent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let command = CLIInstallCommand.symlinkCommand(createDirectory: false,
                                                       linkTarget: fixture.appCLI, destinationURL: fixture.link)
        #expect(try runShell(command) == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path) == fixture.appCLI.path)
    }

    @Test func generatedCommandRefusesExistingDirectoryWithoutMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.link, withIntermediateDirectories: true)
        let command = CLIInstallCommand.symlinkCommand(createDirectory: false,
                                                       linkTarget: fixture.appCLI, destinationURL: fixture.link)
        #expect(try runShell(command) != 0)
        let type = try FileManager.default.attributesOfItem(atPath: fixture.link.path)[.type] as? FileAttributeType
        #expect(type == .typeDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.link.path).isEmpty)
    }

    @Test func generatedCommandRefusesDanglingSymlinkWithoutMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missing = fixture.root.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: fixture.link, withDestinationURL: missing)
        let command = CLIInstallCommand.symlinkCommand(createDirectory: false,
                                                       linkTarget: fixture.appCLI, destinationURL: fixture.link)
        #expect(try runShell(command) != 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.link.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func resolverPrefersRunningBundleInsideApprovedLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIResolve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let global = try makeInstalledApp(in: root.appendingPathComponent("GlobalApplications"))
        let home = try makeInstalledApp(in: root.appendingPathComponent("Applications"))

        // Running from an approved ~/Applications copy links that copy, not the /Applications one.
        let resolved = CLIInstallSource.resolve(bundleURL: home,
                                                searchLocations: [root.appendingPathComponent("GlobalApplications"),
                                                                  root.appendingPathComponent("Applications")])
        #expect(resolved == home.appendingPathComponent("Contents/MacOS/ezs"))
        #expect(global.path != resolved?.path)
    }

    @Test func resolverRequiresInstalledApplicationWithAppSuffix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIResolve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        let installed = try makeInstalledApp(in: applications)
        let installedCLI = installed.appendingPathComponent("Contents/MacOS/ezs")

        // Transient (non-.app) running bundle resolves to the installed copy via a fixed app name.
        #expect(CLIInstallSource.resolve(bundleURL: root.appendingPathComponent("dist/EZSwitch"),
                                         searchLocations: [applications]) == installedCLI)
        // No installed copy -> nil (UI shows "install location required").
        #expect(CLIInstallSource.resolve(bundleURL: root.appendingPathComponent("dist/EZSwitch.app"),
                                         searchLocations: [root.appendingPathComponent("empty")]) == nil)
    }

    @Test func privilegedProbeFollowsWritableAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIPriv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(CLIInstallPrivilege.requiresAuthorization(destinationDirectory: root) == false)
        #expect(CLIInstallPrivilege.requiresAuthorization(destinationDirectory: root.appendingPathComponent("missing/deep")) == false)
    }

    @Test func shellQuoteEscapesSingleQuotesOnly() {
        #expect(CLIInstallCommand.shellQuote("/usr/local/bin/ezs") == "'/usr/local/bin/ezs'")
        #expect(CLIInstallCommand.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func appleScriptLiteralEscapesBackslashesAndDoubleQuotes() {
        #expect(CLIInstallCommand.appleScriptLiteral(forShellCommand: "a\"b\\c") == "\"a\\\"b\\\\c\"")
    }

    @Test func symlinkCommandIsFixedAndNeverForces() {
        let target = URL(fileURLWithPath: "/Applications/EZ Switch.app/Contents/MacOS/ezs")
        let destination = URL(fileURLWithPath: "/usr/local/bin/ezs")
        let command = CLIInstallCommand.symlinkCommand(createDirectory: true, linkTarget: target, destinationURL: destination)
        #expect(command.hasPrefix("/bin/mkdir -p '/usr/local/bin' && [ ! -e '/usr/local/bin/ezs' ] "
            + "&& [ ! -L '/usr/local/bin/ezs' ] && /bin/ln -sh "))
        #expect(command.contains("'/Applications/EZ Switch.app/Contents/MacOS/ezs'"))
        #expect(command.contains(" '/usr/local/bin/ezs'"))
        #expect(!command.contains(" -f"))
    }

    @Test func administratorScriptUsesNativePrivilegesAndDoubleEscapes() {
        let command = CLIInstallCommand.symlinkCommand(createDirectory: false,
                                                       linkTarget: URL(fileURLWithPath: "/Applications/EZSwitch.app/Contents/MacOS/ezs"),
                                                       destinationURL: URL(fileURLWithPath: "/usr/local/bin/ezs"))
        let script = CLIInstallCommand.administratorShellScript(forShellCommand: command)
        #expect(script.hasPrefix("do shell script \""))
        #expect(script.hasSuffix("\" with administrator privileges"))
        #expect(!script.contains("sudo"))
    }

    // MARK: - helpers

    private func makeInstalledApp(in location: URL) throws -> URL {
        let app = location.appendingPathComponent("EZSwitch.app")
        let cli = app.appendingPathComponent("Contents/MacOS/ezs")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return app
    }

    private func runShell(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
