import Foundation

public enum ScreenCaptureContentStatus: Equatable {
    case available
    case accessDenied
    case unavailable
}

public enum ScreenCaptureContentRequestOrigin: Equatable {
    case automatic
    case userInitiated
}

public enum ScreenCaptureContentRefreshDecision: Equatable {
    case complete(status: ScreenCaptureContentStatus)
    case showPermissionGuide(status: ScreenCaptureContentStatus)
}

public enum ScreenCaptureContentRefreshPolicy {
    public static func decision(
        for status: ScreenCaptureContentStatus,
        origin: ScreenCaptureContentRequestOrigin
    ) -> ScreenCaptureContentRefreshDecision {
        guard status == .accessDenied, origin == .userInitiated else {
            return .complete(status: status)
        }
        return .showPermissionGuide(status: status)
    }
}

public final class ScreenCapturePermissionPromptGate {
    private let lock = NSLock()
    private var isPromptInFlight = false

    public init() {}

    public func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isPromptInFlight else { return false }
        isPromptInFlight = true
        return true
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        isPromptInFlight = false
    }
}
