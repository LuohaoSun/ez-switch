import SwiftUI
import AppKit

/// 预设供应商品牌图标，按品牌 key（= `ProviderPreset.iconName`）加载离线 PNG。
///
/// 资源在 `EZSwitch_EZSwitch.bundle/ProviderIcons/`：`.app` 内先在
/// `Bundle.main.resourceURL` 下查找该 bundle，找不到再回退 `Bundle.module`
/// （swift run / swift test），所以 `.app` 不依赖开发期的 `.build`。
struct ProviderPresetIcon: View {
    /// 品牌图标 key（= `ProviderPreset.iconName`）。
    let iconName: String
    /// 无障碍标签，通常是供应商 / 预设的显示名。
    let label: String

    /// 预设卡片的品牌图标。
    init(preset: ProviderPreset) {
        self.init(brandKey: preset.iconName, label: preset.name)
    }

    /// 已存在供应商：按解析出的品牌 key 渲染（见 `ProviderBrandResolver`）。
    init(brandKey: String, label: String) {
        self.iconName = brandKey
        self.label = label
    }

    var body: some View {
        let asset = ProviderPresetIconAsset(name: iconName)
        Group {
            if let nsImage = asset.image {
                Image(nsImage: nsImage)
                    .renderingMode(asset.isTemplate ? .template : .original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: ProviderPresetIconAsset.fallbackSymbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text(label))
    }
}

/// 一张图标资源：归一化后的品牌 key、位图，以及是否为单色（template 着色为 `Color.primary`）。
struct ProviderPresetIconAsset {
    let name: String
    let image: NSImage?
    let isTemplate: Bool

    /// 仅用于没有品牌资源的预设（如自定义供应商），不替代已收录品牌。
    static let fallbackSymbolName = "cube"

    init(name: String) {
        let key = ProviderPresetIconStore.normalized(name)
        self.name = key
        self.isTemplate = ProviderPresetIconStore.isMonochrome(key)
        self.image = ProviderPresetIconStore.image(named: key)
    }
}

enum ProviderPresetIconStore {
    static let resourceDirectoryName = "ProviderIcons"
    static let resourceBundleName = "EZSwitch_EZSwitch.bundle"
    static let resourceExtension = "png"

    /// 已收录品牌 key，与 `ProviderPreset.iconName` 对应。
    static let brandNames: [String] = [
        "zhipu", "zai", "opencode", "commandcode", "openai", "anthropic", "google",
        "deepseek", "kimi", "minimax", "alibaba", "siliconflow", "openrouter",
    ]

    /// 单色品牌图标：运行时以 template 着色为 `Color.primary`（深浅色自适应）；
    /// 其余图标保留上游品牌色。
    static let monochromeBrandNames: Set<String> = [
        "zai", "opencode", "commandcode", "openai", "anthropic", "kimi", "openrouter",
    ]

    static let resourceBundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isMonochrome(_ name: String) -> Bool {
        monochromeBrandNames.contains(normalized(name))
    }

    static func image(named name: String) -> NSImage? {
        let key = normalized(name)
        guard !key.isEmpty,
              key.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
        else { return nil }

        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let url = resourceBundle.url(forResource: key,
                                           withExtension: resourceExtension,
                                           subdirectory: resourceDirectoryName),
              let image = NSImage(contentsOf: url)
        else { return nil }

        image.isTemplate = isMonochrome(key)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static let cache = NSCache<NSString, NSImage>()
}
