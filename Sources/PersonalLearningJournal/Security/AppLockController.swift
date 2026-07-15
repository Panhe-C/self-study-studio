import Combine
import Foundation
import LocalAuthentication

public protocol DeviceOwnerAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

public struct LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    public init() {}

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

@MainActor
public final class AppLockController: ObservableObject {
    public static let shared = AppLockController(
        isEnabled: UserDefaults.standard.bool(forKey: "appLockEnabled"),
        authenticator: LocalDeviceOwnerAuthenticator(),
        persistEnabled: { UserDefaults.standard.set($0, forKey: "appLockEnabled") }
    )

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isUnlocked: Bool
    @Published public private(set) var showsPrivacyCover: Bool

    private let authenticator: any DeviceOwnerAuthenticating
    private let persistEnabled: (Bool) -> Void

    public init(
        isEnabled: Bool = false,
        authenticator: any DeviceOwnerAuthenticating,
        persistEnabled: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isEnabled = isEnabled
        self.isUnlocked = !isEnabled
        self.showsPrivacyCover = isEnabled
        self.authenticator = authenticator
        self.persistEnabled = persistEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        isUnlocked = !enabled
        showsPrivacyCover = enabled
        persistEnabled(enabled)
    }

    @discardableResult
    public func unlock() async -> Bool {
        guard isEnabled else {
            isUnlocked = true
            showsPrivacyCover = false
            return true
        }
        let authenticated = await authenticator.authenticate(
            reason: "Unlock Self Study Studio to view your learning journal."
        )
        isUnlocked = authenticated
        showsPrivacyCover = !authenticated
        return authenticated
    }

    public func applicationDidEnterBackground() {
        showsPrivacyCover = true
        if isEnabled { isUnlocked = false }
    }

    public func applicationDidBecomeActive() async {
        if isEnabled { _ = await unlock() }
        else {
            isUnlocked = true
            showsPrivacyCover = false
        }
    }
}
