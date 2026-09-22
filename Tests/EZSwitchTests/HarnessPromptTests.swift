import XCTest
@testable import EZSwitch

final class HarnessPromptTests: XCTestCase {
    func testPromptContainsDynamicEndpointAndModel() {
        let prompt = HarnessPrompt.make(
            endpoint: "http://127.0.0.1:8799/v1",
            modelIDs: ["main", "ultra", "sub"]
        )

        XCTAssertTrue(prompt.contains("- 端点：http://127.0.0.1:8799/v1"))
        XCTAssertTrue(prompt.contains("- 密钥：任意占位符（例如 ez-switch-local）"))
        XCTAssertTrue(prompt.contains("- 模型：main、ultra、sub"))
    }

    func testPromptUsesPlaceholderWhenNoModelIsAvailable() {
        let prompt = HarnessPrompt.make(
            endpoint: "http://127.0.0.1:8788/v1",
            modelIDs: []
        )

        XCTAssertTrue(prompt.contains("- 模型：<model-id>"))
    }
}
