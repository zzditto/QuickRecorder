import CoreMedia
import Foundation

public enum RecordingSampleRetimer {
    public static func copy(_ sampleBuffer: CMSampleBuffer?, presentationTime: CMTime) -> CMSampleBuffer? {
        guard let sampleBuffer else { return nil }

        var timingEntryCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingEntryCount
        ) == noErr, timingEntryCount > 0 else {
            return nil
        }

        var timingInfo = Array(repeating: CMSampleTimingInfo(), count: timingEntryCount)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timingEntryCount,
            arrayToFill: &timingInfo,
            entriesNeededOut: nil
        ) == noErr else {
            return nil
        }

        let originalPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        for index in timingInfo.indices {
            let offset = CMTimeSubtract(timingInfo[index].presentationTimeStamp, originalPresentationTime)
            timingInfo[index].presentationTimeStamp = CMTimeAdd(presentationTime, offset)
        }

        var retimedSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingEntryCount,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &retimedSampleBuffer
        ) == noErr else {
            return nil
        }
        return retimedSampleBuffer
    }
}
