import SwiftUI

/// “添加供应商”两步流程状态：预设列表 ↔ 连接设置。
/// 选择预设只更新草稿，不写 ConfigStore；落盘仍由 `RemoteEditSheet` 保存负责。
@MainActor
final class ProviderPresetDraft: ObservableObject {
    enum Stage: Equatable {
        case presets
        case connection
    }

    @Published var stage: Stage = .presets
    @Published var selectedPreset: ProviderPreset?
    @Published var query = ""

    func choose(_ preset: ProviderPreset) {
        selectedPreset = preset
        stage = .connection
    }

    func chooseCustom() {
        selectedPreset = nil
        stage = .connection
    }

    /// 返回并丢弃尚未保存的选择。
    func backToPresets() {
        selectedPreset = nil
        stage = .presets
    }

    func matchingPresets(in all: [ProviderPreset]) -> [ProviderPreset] {
        all.filter { $0.matches(query: query) }
    }
}

/// 新增预设时避免与现有供应商重名：占用则顺延 “名称 2 / 名称 3 …”。
enum ProviderPresetNaming {
    static func suggestedName(base: String, existing: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.contains(trimmed) else { return trimmed }
        var suffix = 2
        while existing.contains("\(trimmed) \(suffix)") { suffix += 1 }
        return "\(trimmed) \(suffix)"
    }
}

struct ProviderPresetPicker: View {
    @ObservedObject var draft: ProviderPresetDraft
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private var showsSearch: Bool { ProviderPreset.all.count > 6 }
    private var presets: [ProviderPreset] { draft.matchingPresets(in: ProviderPreset.all) }

    var body: some View {
        VStack(spacing: 0) {
            Text("添加供应商")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            if showsSearch {
                TextField("搜索供应商", text: $draft.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(presets) { preset in
                        presetCard(preset)
                    }
                    customCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 540)
    }

    private func presetCard(_ preset: ProviderPreset) -> some View {
        Button { draft.choose(preset) } label: {
            VStack(spacing: 8) {
                ProviderPresetIcon(preset: preset)
                    .frame(width: 28, height: 28)
                Text(preset.name).font(.callout).lineLimit(1)
            }
            .cardChrome()
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    private var customCard: some View {
        Button { draft.chooseCustom() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                Text("自定义供应商").font(.callout).lineLimit(1)
            }
            .cardChrome()
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func cardChrome() -> some View {
        self
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// 单一 sheet：内部在预设面板与连接设置之间切换，保持 sheet 身份稳定。
struct NewProviderSheet: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var draft = ProviderPresetDraft()

    var body: some View {
        switch draft.stage {
        case .presets:
            ProviderPresetPicker(draft: draft)
        case .connection:
            RemoteEditSheet(
                store: store,
                source: nil,
                preset: draft.selectedPreset,
                existingProviders: Set(store.groupedRemotes().map(\.provider)),
                onBackToPresets: { draft.backToPresets() }
            )
            .id(draft.selectedPreset?.id ?? "custom-provider")
        }
    }
}
