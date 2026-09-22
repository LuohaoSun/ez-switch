import Foundation
import Testing
@testable import EZSwitch

@Suite("Update checker")
struct UpdateCheckerTests {
    @Test
    func versionComparison() {
        #expect(UpdateVersion.isNewer("0.1.3", than: "0.1.2"))
        #expect(!UpdateVersion.isNewer("0.2.0", than: "0.10.0"))
        #expect(UpdateVersion.isNewer("1.0.0", than: "0.99.99"))
        #expect(!UpdateVersion.isNewer("0.1.2", than: "0.1.2"))
        #expect(!UpdateVersion.isNewer("0.1.1", than: "0.1.2"))
    }

    @Test
    func checksumParser() {
        let checksum = String(repeating: "a", count: 64)
        #expect(UpdateVersion.checksum(from: "\(checksum)  dist/EZSwitch.dmg") == checksum)
        #expect(UpdateVersion.checksum(from: "not-a-checksum") == nil)
    }

    @Test
    func releaseDecodesAndFindsAssets() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/LuohaoSun/ez-switch/releases/tag/v0.2.0",
          "body": "Release notes",
          "assets": [
            {
              "name": "EZSwitch-0.2.0.dmg",
              "browser_download_url": "https://github.com/LuohaoSun/ez-switch/releases/download/v0.2.0/EZSwitch-0.2.0.dmg"
            },
            {
              "name": "EZSwitch-0.2.0.dmg.sha256",
              "browser_download_url": "https://github.com/LuohaoSun/ez-switch/releases/download/v0.2.0/EZSwitch-0.2.0.dmg.sha256"
            }
          ]
        }
        """

        let release = try JSONDecoder().decode(UpdateRelease.self, from: Data(json.utf8))

        #expect(release.version == "0.2.0")
        #expect(release.diskImage?.name == "EZSwitch-0.2.0.dmg")
        #expect(release.checksum?.name == "EZSwitch-0.2.0.dmg.sha256")
    }
}
