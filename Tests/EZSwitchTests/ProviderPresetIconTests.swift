import Testing
import AppKit
@testable import EZSwitch

/// 预设品牌图标资源：确保 catalog 里的每个 iconName 都能解析到随包分发的离线资源，
/// 并校验单色/彩色分类与未知 name 的兜底行为。
@Suite("Provider preset icons")
struct ProviderPresetIconTests {

    @Test
    func everyCatalogPresetResolvesToAnIcon() {
        for preset in ProviderPreset.all {
            let asset = ProviderPresetIconAsset(name: preset.iconName)
            #expect(asset.image != nil,
                    "预设 \(preset.id) 的 iconName=\(preset.iconName) 未找到图标资源")
        }
    }

    @Test
    func everyBrandKeyInCatalogIsDeclared() {
        let used = Set(ProviderPreset.all.map(\.iconName))
        let declared = Set(ProviderPresetIconStore.brandNames)
        #expect(used.isSubset(of: declared),
                "catalog 使用了未声明的品牌图标 key：\(used.subtracting(declared))")
    }

    @Test
    func everyDeclaredBrandKeyHasAResource() {
        for name in ProviderPresetIconStore.brandNames {
            let image = ProviderPresetIconStore.image(named: name)
            #expect(image != nil, "已声明品牌 key \(name) 缺少图标资源")
            #expect(image?.isValid == true, "品牌 key \(name) 的图标资源无法解码")
        }
    }

    @Test
    func monochromeIconsAreMarkedTemplateAndColoredAreNot() {
        for name in ProviderPresetIconStore.brandNames {
            let asset = ProviderPresetIconAsset(name: name)
            #expect(asset.isTemplate == ProviderPresetIconStore.isMonochrome(name))
            // 单色图标必须在 NSImage 上标记 template，彩色图标必须保留原色。
            #expect(asset.image?.isTemplate == asset.isTemplate,
                    "\(name) 的 template 标记与分类不一致")
        }
    }

    @Test
    func iconNameLookupIsCaseAndWhitespaceInsensitive() {
        #expect(ProviderPresetIconStore.image(named: "  OpenAI ") != nil)
        #expect(ProviderPresetIconStore.image(named: "OPENAI") != nil)
    }

    @Test
    func unknownOrUnsafeNamesReturnNil() {
        #expect(ProviderPresetIconStore.image(named: "does-not-exist") == nil)
        #expect(ProviderPresetIconStore.image(named: "") == nil)
        #expect(ProviderPresetIconStore.image(named: "..") == nil)
        #expect(ProviderPresetIconStore.image(named: "../Info") == nil)
        #expect(ProviderPresetIconStore.image(named: "sub/openai") == nil)
    }

    @Test
    func resourceBundleCarriesProviderIconsDirectory() {
        let bundle = ProviderPresetIconStore.resourceBundle
        // 资源 bundle 里应能找到图标子目录（SwiftPM 会把它放进 Contents/Resources）。
        let probe = bundle.url(forResource: "openai",
                               withExtension: ProviderPresetIconStore.resourceExtension,
                               subdirectory: ProviderPresetIconStore.resourceDirectoryName)
        #expect(probe != nil, "资源 bundle 中缺少 \(ProviderPresetIconStore.resourceDirectoryName)/openai.png")
    }

    /// UI 契约：在 28x28 卡片里可用。
    @Test
    @MainActor
    func iconViewCanBeFramedInPresetCard() {
        guard let preset = ProviderPreset.all.first else {
            Issue.record("catalog 为空")
            return
        }
        _ = ProviderPresetIcon(preset: preset).frame(width: 28, height: 28)
    }
}
