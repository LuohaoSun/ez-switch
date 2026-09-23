import Foundation
import ServiceManagement
import Testing
@testable import EZSwitch

@Suite("Login item toggle feedback")
struct LoginItemToggleFeedbackTests {
    @Test
    func pendingApprovalCanBeUnregisteredWithoutRegisteringAgain() {
        #expect(LoginItemToggleEvaluator.action(requestedEnabled: false, status: .requiresApproval) == .unregister)
        #expect(LoginItemToggleEvaluator.action(requestedEnabled: true, status: .requiresApproval) == .none)
    }

    @Test
    func registrationRequiringApprovalKeepsToggleOffAndOffersAction() {
        let result = LoginItemToggleEvaluator.evaluate(
            requestedEnabled: true,
            before: .notRegistered,
            after: .requiresApproval,
            error: nil
        )

        #expect(!result.isEnabled)
        #expect(result.feedback?.retryEnabled == nil)
        #expect(result.feedback?.message.contains("系统设置") == true)
        #expect(result.feedback?.message.contains("允许 EZ Switch") == true)
    }

    @Test
    func thrownRegistrationErrorIncludesReasonAndKeepsActualState() {
        let error = NSError(
            domain: "LoginItemToggleFeedbackTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "签名无效"]
        )

        let result = LoginItemToggleEvaluator.evaluate(
            requestedEnabled: true,
            before: .notRegistered,
            after: .notRegistered,
            error: error
        )

        #expect(!result.isEnabled)
        #expect(result.feedback?.retryEnabled == true)
        #expect(result.feedback?.message.contains("签名无效") == true)
        #expect(result.feedback?.message.contains("重试") == true)
    }

    @Test
    func failedDisableLeavesToggleOnAndExplainsTheState() {
        let error = NSError(
            domain: "LoginItemToggleFeedbackTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "操作被拒绝"]
        )

        let result = LoginItemToggleEvaluator.evaluate(
            requestedEnabled: false,
            before: .enabled,
            after: .enabled,
            error: error
        )

        #expect(result.isEnabled)
        #expect(result.feedback?.retryEnabled == false)
        #expect(result.feedback?.message.contains("无法关闭登录项") == true)
        #expect(result.feedback?.message.contains("操作被拒绝") == true)
    }

    @Test
    func successfulDisableWhileApprovalIsPendingClearsFeedback() {
        let result = LoginItemToggleEvaluator.evaluate(
            requestedEnabled: false,
            before: .requiresApproval,
            after: .notRegistered,
            error: nil
        )

        #expect(!result.isEnabled)
        #expect(result.feedback == nil)
    }

    @Test
    func failedDisableWhileApprovalIsPendingIsReported() {
        let error = NSError(
            domain: "LoginItemToggleFeedbackTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "无法移除待批准项"]
        )

        let result = LoginItemToggleEvaluator.evaluate(
            requestedEnabled: false,
            before: .requiresApproval,
            after: .requiresApproval,
            error: error
        )

        #expect(!result.isEnabled)
        #expect(result.feedback?.retryEnabled == false)
        #expect(result.feedback?.message.contains("无法关闭登录项") == true)
        #expect(result.feedback?.message.contains("无法移除待批准项") == true)
    }

    @Test
    func successfulToggleUsesTheActualPostOperationState() {
        let result = LoginItemToggleEvaluator.evaluate(
            requestedEnabled: false,
            before: .enabled,
            after: .notRegistered,
            error: nil
        )

        #expect(!result.isEnabled)
        #expect(result.feedback == nil)
    }
}
