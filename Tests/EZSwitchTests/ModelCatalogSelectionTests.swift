import Testing
@testable import EZSwitch

/// 目录草稿的纯逻辑：初始勾选、重新获取合并、变更判定。
/// 这些语义决定 sheet 是否写入配置，因此单独覆盖；“取消不写入”由纯函数 + 只在确认时调用 store 保证。
@Suite("Model catalog draft selection")
struct ModelCatalogSelectionTests {
    // MARK: 初始勾选

    @Test func initialSelectionChecksOnlyExistingFetchedModels() {
        // 本次返回 a/b/c，本地已有 b/c；另有本地已有但未返回的 x 不出现。
        let selected = ModelCatalogSelection.initialSelection(models: ["a", "b", "c"],
                                                             existing: ["b", "c", "x"])
        #expect(selected == ["b", "c"])
        // 首次展开时应用按钮应无变更可提交。
        #expect(!ModelCatalogSelection.hasPendingChanges(selected: selected,
                                                         choices: ["a", "b", "c"],
                                                         existing: ["b", "c", "x"]))
    }

    @Test func initialSelectionIsEmptyWhenNothingFetched() {
        #expect(ModelCatalogSelection.initialSelection(models: [], existing: ["a"]).isEmpty)
    }

    // MARK: 重新获取

    @Test func refetchPreservesDraftForPreviouslyDisplayedIDs() {
        // 此前展示 [a,b] 且用户只勾了 a；重新获取仍返回 a/b，并新增 c（本地已有）。
        let selected = ModelCatalogSelection.selectionAfterRefetch(
            models: ["a", "b", "c"],
            previouslyDisplayed: ["a", "b"],
            previousSelection: ["a"],
            existing: ["a", "b", "c"])
        // a 沿用勾选；b 沿用“用户取消”的状态（尽管本地已有）；c 为新返回且本地已有 → 勾选。
        #expect(selected == ["a", "c"])
    }

    @Test func refetchPreservesUserUncheckEvenWhenStillExisting() {
        // 用户把本地已有的 a 取消勾选后重新获取，仍返回 a：不能因为 a 存在于配置就重新勾上。
        let selected = ModelCatalogSelection.selectionAfterRefetch(
            models: ["a"],
            previouslyDisplayed: ["a"],
            previousSelection: [],
            existing: ["a"])
        #expect(selected.isEmpty)
    }

    @Test func refetchInitializesNewIDsFromCurrentConfig() {
        // 新返回的 d/e：d 本地已有 → 勾选；e 本地没有 → 不勾选。
        let selected = ModelCatalogSelection.selectionAfterRefetch(
            models: ["d", "e"],
            previouslyDisplayed: [],
            previousSelection: [],
            existing: ["d"])
        #expect(selected == ["d"])
    }

    @Test func refetchDropsSelectionForIDsThatDisappear() {
        // b 不再返回 → 不在 choices 内，草稿里也不再保留（但配置不会被触碰）。
        let selected = ModelCatalogSelection.selectionAfterRefetch(
            models: ["a"],
            previouslyDisplayed: ["a", "b"],
            previousSelection: ["a", "b"],
            existing: ["a", "b"])
        #expect(selected == ["a"])
    }

    // MARK: 变更判定（决定应用按钮是否可用）

    @Test func detectsAdditionRemovalAndNoChange() {
        // 新增：勾选了一个本地不存在的模型。
        #expect(ModelCatalogSelection.hasPendingChanges(selected: ["a"],
                                                         choices: ["a", "b"], existing: []))
        // 删除：本地已有 a/b，只保留了 b → a 待删除。
        #expect(ModelCatalogSelection.hasPendingChanges(selected: ["b"],
                                                         choices: ["a", "b"], existing: ["a", "b"]))
        // 无变更：勾选与“本地已有 ∩ 本次返回”一致。
        #expect(!ModelCatalogSelection.hasPendingChanges(selected: ["a"],
                                                         choices: ["a", "b"], existing: ["a"]))
    }

    @Test func hiddenExistingModelsAreNeverCountedOrRemoved() {
        // 本地有 hidden，但本次未返回：它不在 choices/基线内，因此不产生变更，也不会被删除。
        #expect(!ModelCatalogSelection.hasPendingChanges(selected: [],
                                                         choices: [], existing: ["hidden"]))
        #expect(!ModelCatalogSelection.hasPendingChanges(selected: ["a"],
                                                         choices: ["a"], existing: ["a", "hidden"]))
        // 勾选集合本身也只可能包含本次返回的 ID。
        let selected = ModelCatalogSelection.initialSelection(models: ["a"], existing: ["a", "hidden"])
        #expect(!selected.contains("hidden"))
    }
}
