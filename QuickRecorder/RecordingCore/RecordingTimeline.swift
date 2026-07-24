import CoreMedia
import Foundation

import CoreMedia
import Foundation

public struct RecordingTimeline {
    public private(set) var sourceStartTime: CMTime?
    public private(set) var accumulatedPauseDuration: CMTime = .zero
    public private(set) var lastPresentationTime: CMTime = .zero
    private var pauseStartSourceTime: CMTime?

    public init() {}

    public var isPaused: Bool { pauseStartSourceTime != nil }

    public mutating func presentationTime(for sourceTime: CMTime) -> CMTime {
        if sourceStartTime == nil {
            sourceStartTime = sourceTime
        }
        guard let start = sourceStartTime else { return .zero }
        let relative = CMTimeSubtract(sourceTime, start)
        let mapped = CMTimeMaximum(.zero, CMTimeSubtract(relative, accumulatedPauseDuration))
        lastPresentationTime = CMTimeMaximum(lastPresentationTime, mapped)
        return lastPresentationTime
    }

    public mutating func pause(at sourceTime: CMTime) {
        guard pauseStartSourceTime == nil else { return }
        pauseStartSourceTime = sourceTime
    }

    public mutating func resume(at sourceTime: CMTime) {
        guard let pauseStart = pauseStartSourceTime else { return }
        accumulatedPauseDuration = CMTimeAdd(
            accumulatedPauseDuration,
            CMTimeMaximum(.zero, CMTimeSubtract(sourceTime, pauseStart))
        )
        pauseStartSourceTime = nil
    }

    public mutating func finalDuration(at sourceTime: CMTime) -> CMTime {
        presentationTime(for: sourceTime)
    }
}
