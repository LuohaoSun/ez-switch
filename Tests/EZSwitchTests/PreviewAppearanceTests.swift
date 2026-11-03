import Testing
@testable import EZSwitch

@Suite("Preview appearance options")
struct PreviewAppearanceTests {
    private let bundleID = "local.sunluohao.ezswitch.stylecheck"
    private let configPath = "/tmp/ezswitch-style-fixture/config.json"

    // MARK: - 门禁

    @Test
    func bundleGateRequiresStyleCheckSuffix() {
        #expect(PreviewOptions.isStyleCheckBundle(identifier: bundleID))
        #expect(!PreviewOptions.isStyleCheckBundle(identifier: "local.sunluohao.ezswitch"))
        #expect(!PreviewOptions.isStyleCheckBundle(identifier: "local.sunluohao.ezswitch.stylecheck.extra"))
        #expect(!PreviewOptions.isStyleCheckBundle(identifier: "local.sunluohao.ezswitchXstylecheck"))
        #expect(!PreviewOptions.isStyleCheckBundle(identifier: nil))
        #expect(!PreviewOptions.isStyleCheckBundle(identifier: ""))
    }

    @Test
    func configGateRequiresIsolatedFixtureDirectory() {
        #expect(PreviewOptions.isIsolatedConfigPath(configPath))
        #expect(PreviewOptions.isIsolatedConfigPath("/private/tmp/ezswitch-style-fixture/config.json"))
        #expect(PreviewOptions.isIsolatedConfigPath("/tmp/ezswitch-style-fixture"))
        #expect(PreviewOptions.isIsolatedConfigPath("/tmp/ezswitch-style-fixture/"))

        #expect(!PreviewOptions.isIsolatedConfigPath("/tmp/other/config.json"))
        #expect(!PreviewOptions.isIsolatedConfigPath("/tmp/ezswitch-style-fixture-old/config.json"))
        #expect(!PreviewOptions.isIsolatedConfigPath(
            "/Users/sunluohao/Library/Application Support/EZSwitch/config.json"))
        #expect(!PreviewOptions.isIsolatedConfigPath("relative/config.json"))
        #expect(!PreviewOptions.isIsolatedConfigPath(
            "/tmp/ezswitch-style-fixture/../ezswitch-other/config.json"))
        #expect(!PreviewOptions.isIsolatedConfigPath(nil))
        #expect(!PreviewOptions.isIsolatedConfigPath(""))
    }

    // MARK: - 取值解析

    @Test
    func appearanceAcceptsOnlyDocumentedValues() {
        #expect(PreviewAppearance(rawValue: "light") == .light)
        #expect(PreviewAppearance(rawValue: "dark") == .dark)
        #expect(PreviewAppearance(rawValue: "Dark") == nil)
        #expect(PreviewAppearance(rawValue: "system") == nil)
        #expect(PreviewAppearance(rawValue: "") == nil)
    }

    @Test
    func sizeAcceptsOnlyDocumentedValues() {
        #expect(PreviewWindowSize.allowedRawValues == ["1000x760", "1120x760", "1401x1066"])
        for rawValue in PreviewWindowSize.allowedRawValues {
            #expect(PreviewWindowSize(rawValue: rawValue) != nil)
        }

        let large = PreviewWindowSize(rawValue: "1401x1066")
        #expect(large?.width == 1401)
        #expect(large?.height == 1066)

        let padded = PreviewWindowSize(rawValue: "  1120x760\n")
        #expect(padded?.width == 1120)
        #expect(padded?.height == 760)

        #expect(PreviewWindowSize(rawValue: "1000X760") == nil)
        #expect(PreviewWindowSize(rawValue: "1920x1080") == nil)
        #expect(PreviewWindowSize(rawValue: "1000x") == nil)
        #expect(PreviewWindowSize(rawValue: "") == nil)
        #expect(PreviewWindowSize(rawValue: nil) == nil)
    }

    // MARK: - 组合解析

    @Test
    func resolvesAppearanceAndSizeTogether() throws {
        let configuration = try #require(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_CONFIG": configPath,
                "EZSWITCH_PREVIEW_APPEARANCE": "dark",
                "EZSWITCH_PREVIEW_SIZE": "1401x1066",
            ]))

        #expect(configuration.appearance == .dark)
        #expect(configuration.contentSize == PreviewWindowSize(rawValue: "1401x1066"))
        #expect(configuration.isActive)
    }

    @Test
    func resolvesOptionalDimensionsIndependently() throws {
        let appearanceOnly = try #require(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_CONFIG": configPath,
                "EZSWITCH_PREVIEW_APPEARANCE": "light",
            ]))
        #expect(appearanceOnly.appearance == .light)
        #expect(appearanceOnly.contentSize == nil)

        let sizeOnly = try #require(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_CONFIG": configPath,
                "EZSWITCH_PREVIEW_SIZE": "1000x760",
            ]))
        #expect(sizeOnly.appearance == nil)
        #expect(sizeOnly.contentSize == PreviewWindowSize(rawValue: "1000x760"))
    }

    @Test
    func rejectsProductionBundleEvenWithPreviewEnvironment() {
        #expect(PreviewOptions.resolve(
            bundleIdentifier: "local.sunluohao.ezswitch",
            environment: [
                "EZSWITCH_CONFIG": configPath,
                "EZSWITCH_PREVIEW_APPEARANCE": "dark",
                "EZSWITCH_PREVIEW_SIZE": "1401x1066",
            ]) == nil)
    }

    @Test
    func rejectsProductionConfigPathEvenWithStyleCheckBundle() {
        #expect(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_CONFIG": "/Users/sunluohao/Library/Application Support/EZSwitch/config.json",
                "EZSWITCH_PREVIEW_APPEARANCE": "dark",
            ]) == nil)

        #expect(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_PREVIEW_APPEARANCE": "dark",
            ]) == nil)
    }

    @Test
    func noOptionsMeansInactive() {
        #expect(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: ["EZSWITCH_CONFIG": configPath]) == nil)

        #expect(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_CONFIG": configPath,
                "EZSWITCH_PREVIEW_APPEARANCE": "  ",
                "EZSWITCH_PREVIEW_SIZE": "",
            ]) == nil)
    }

    @Test
    func invalidOptionRejectsWholeConfiguration() {
        // 宁可完全不生效，也不要静默回落到系统外观或默认尺寸。
        #expect(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_CONFIG": configPath,
                "EZSWITCH_PREVIEW_APPEARANCE": "sepia",
                "EZSWITCH_PREVIEW_SIZE": "1000x760",
            ]) == nil)

        #expect(PreviewOptions.resolve(
            bundleIdentifier: bundleID,
            environment: [
                "EZSWITCH_CONFIG": configPath,
                "EZSWITCH_PREVIEW_APPEARANCE": "dark",
                "EZSWITCH_PREVIEW_SIZE": "1920x1080",
            ]) == nil)
    }
}
