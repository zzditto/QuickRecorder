import AVFoundation
import CoreMedia
import Foundation

public struct AECAudioClock {
    private let sampleRate: Double
    private var nextTime: CMTime

    public init(sampleRate: Double, startTime: CMTime) {
        self.sampleRate = sampleRate
        self.nextTime = startTime
    }

    public mutating func nextSourceTime(frameLength: AVAudioFrameCount) -> CMTime {
        let current = nextTime
        let step = CMTime(
            seconds: Double(frameLength) / sampleRate,
            preferredTimescale: 1_000_000_000
        )
        nextTime = CMTimeAdd(nextTime, step)
        return current
    }
}
