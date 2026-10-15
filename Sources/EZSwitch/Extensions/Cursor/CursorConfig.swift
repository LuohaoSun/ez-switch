import Foundation

/// Cursor 连接器的配置与生命周期便捷封装，全部建立在通用 seam 之上：
/// `ConnectorSettings`、扩展配置键 `CursorExtension.settingsKey`、通用
/// `ConfigStore` 方法。只存在于扩展目录内，主干不保留任何 Cursor 专有 API。
typealias CursorConnectorSettings = ConnectorSettings

extension ExtensionSettings {
    /// Cursor 扩展配置节点（键为 `CursorExtension.settingsKey`）。
    /// 读写都经通用 `connectorSettings(for:)`，持久化格式由存储层决定。
    var cursorConnector: CursorConnectorSettings {
        get { connectorSettings(for: CursorExtension.settingsKey) }
        set { setConnectorSettings(newValue, for: CursorExtension.settingsKey) }
    }
}

extension ConfigStore {
    /// 只切换总开关，保留绑定与供应商记录；关闭只让 Cursor 候选不可用。
    func setCursorConnectorEnabled(_ enabled: Bool) {
        setConnectorEnabled(settingsKey: CursorExtension.settingsKey, enabled: enabled)
    }

    /// 原子创建/补齐 Cursor 供应商记录并绑定（幂等）；记录恒为连接来源身份、
    /// 空凭据、原生端点全关，模型 ID 须来自已验证目录。
    @discardableResult
    func addCursorProvider(modelIDs: [String], named name: String = CursorExtension.displayName) -> String? {
        addConnectorProvider(source: CursorExtension.source, settingsKey: CursorExtension.settingsKey,
                             modelIDs: modelIDs, named: name)
    }

    /// 解除绑定但保留记录（记录随之不可用）；不删除供应商、模型或路由。
    func removeCursorProvider() {
        removeConnectorProvider(settingsKey: CursorExtension.settingsKey)
    }
}
