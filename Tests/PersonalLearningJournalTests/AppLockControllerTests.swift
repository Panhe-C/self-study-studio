import XCTest
@testable import PersonalLearningJournal

@MainActor
final class AppLockControllerTests: XCTestCase {
    func testLockIsDisabledAndUnlockedByDefault() {
        let controller = AppLockController(authenticator: FakeDeviceOwnerAuthenticator(result: true))

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.isUnlocked)
        XCTAssertFalse(controller.showsPrivacyCover)
    }

    func testBackgroundLocksAndSuccessfulActivationUnlocks() async {
        let controller = AppLockController(
            isEnabled: true,
            authenticator: FakeDeviceOwnerAuthenticator(result: true)
        )

        controller.applicationDidEnterBackground()
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertTrue(controller.showsPrivacyCover)

        let didUnlock = await controller.unlock()
        XCTAssertTrue(didUnlock)
        XCTAssertTrue(controller.isUnlocked)
        XCTAssertFalse(controller.showsPrivacyCover)
    }

    func testFailedAuthenticationKeepsProtectedContentCovered() async {
        let controller = AppLockController(
            isEnabled: true,
            authenticator: FakeDeviceOwnerAuthenticator(result: false)
        )

        let didUnlock = await controller.unlock()
        XCTAssertFalse(didUnlock)
        XCTAssertFalse(controller.isUnlocked)
        XCTAssertTrue(controller.showsPrivacyCover)
    }
}

private struct FakeDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    let result: Bool
    func authenticate(reason: String) async -> Bool { result }
}
