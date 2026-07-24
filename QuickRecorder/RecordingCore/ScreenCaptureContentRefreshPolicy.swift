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

public struct ScreenCaptureContentRefreshRequest: Equatable {
    public let origin: ScreenCaptureContentRequestOrigin
    public let onScreenWindowsOnly: Bool

    public init(origin: ScreenCaptureContentRequestOrigin, onScreenWindowsOnly: Bool) {
        self.origin = origin
        self.onScreenWindowsOnly = onScreenWindowsOnly
    }

    public static let automatic = Self(origin: .automatic, onScreenWindowsOnly: false)
    public static let userInitiated = Self(origin: .userInitiated, onScreenWindowsOnly: false)
    public static let windowSelection = Self(origin: .userInitiated, onScreenWindowsOnly: true)
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

public final class ScreenCaptureSelectionSessionCoordinator {
    public static let firstLoadRequest = ScreenCaptureContentRefreshRequest.userInitiated

    private let lock = NSLock()
    private var currentSession: UInt64 = 0
    private var listenerSession: UInt64?
    private var storedTargetWindowID: Int?

    public init() {}

    public var targetWindowID: Int? {
        lock.lock()
        defer { lock.unlock() }

        return storedTargetWindowID
    }

    @discardableResult
    public func beginSession() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        currentSession &+= 1
        listenerSession = currentSession
        storedTargetWindowID = nil
        return currentSession
    }

    public func stopListening() {
        lock.lock()
        defer { lock.unlock() }

        listenerSession = nil
        storedTargetWindowID = nil
    }

    public func invalidateCurrentSession() {
        lock.lock()
        defer { lock.unlock() }

        currentSession &+= 1
        listenerSession = nil
        storedTargetWindowID = nil
    }

    @discardableResult
    public func invalidateSession(_ session: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard session == currentSession else { return false }

        currentSession &+= 1
        listenerSession = nil
        storedTargetWindowID = nil
        return true
    }

    public func currentSessionToken() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        return currentSession
    }

    public func isCurrent(_ session: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return session == currentSession
    }

    public func canHandleMouseEvent(_ eventSession: UInt64, listenerSession: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return eventSession == currentSession
            && listenerSession == currentSession
            && self.listenerSession == listenerSession
    }

    public func canApplySelectionCompletion(for session: UInt64) -> Bool {
        isCurrent(session)
    }

    @discardableResult
    public func selectTargetWindow(
        _ windowID: Int,
        for eventSession: UInt64,
        listenerSession: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard eventSession == currentSession,
              listenerSession == currentSession,
              self.listenerSession == listenerSession else {
            return false
        }

        storedTargetWindowID = windowID
        return true
    }

    @discardableResult
    public func clearTargetWindowID(for session: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard session == currentSession else { return false }
        storedTargetWindowID = nil
        return true
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
