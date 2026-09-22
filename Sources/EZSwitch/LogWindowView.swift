import SwiftUI
import AppKit

@MainActor
final class LogModel: ObservableObject {
    @Published var text = ""
    @Published var query = ""
    @Published var paused = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        guard !paused else { return }
        let latest = Log.shared.recent()
        if latest != text { text = latest }
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    var lines: [String] {
        text.components(separatedBy: .newlines).filter {
            !$0.isEmpty && (query.isEmpty || $0.localizedCaseInsensitiveContains(query))
        }.reversed()
    }
}

struct LogWindowView: View {
    @StateObject private var model = LogModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近活动").font(.title2.bold())
                    Text(model.paused ? "已暂停刷新，可选中和复制日志。" : "每秒更新 · 保留最近 300 条日志")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.paused ? "已暂停" : "实时", systemImage: model.paused ? "pause.circle" : "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            if model.lines.isEmpty {
                EmptyState(title: model.query.isEmpty ? "暂无活动" : "没有匹配的日志",
                           detail: model.query.isEmpty ? "服务启动和请求记录会显示在这里。" : "尝试搜索模型 ID、状态码或错误信息。", symbol: "waveform.path.ecg")
                Spacer()
            } else {
                // 最新日志固定在顶部，切换路由后不需要再滚到长列表底部确认。
                List(Array(model.lines.enumerated()), id: \.offset) { entry in
                    Text(entry.element)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.listStyle(.inset)
            }
        }
        .navigationTitle("活动")
        .searchable(text: $model.query, prompt: "搜索日志")
        .background(WindowActivator().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.paused.toggle()
                    model.refresh()
                } label: {
                    Label(model.paused ? "继续" : "暂停", systemImage: model.paused ? "play" : "pause")
                }
                Button { copyText(model.lines.joined(separator: "\n")) } label: {
                    Label("复制日志", systemImage: "doc.on.doc")
                }.disabled(model.lines.isEmpty)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
