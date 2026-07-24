import AVFoundation
import CoreMedia
import Foundation

public enum AudioSampleBufferFactory {
    public static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        guard buffer.format.sampleRate > 0 else {
            return nil
        }
        let streamDescription = buffer.format.streamDescription

        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(
                seconds: 1 / buffer.format.sampleRate,
                preferredTimescale: 1_000_000_000
            ),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var dataBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 0,
            flags: 0,
            blockBufferOut: &dataBuffer
        ) == noErr, let dataBuffer else {
            return nil
        }

        var dataOffset = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            let byteCount = Int(audioBuffer.mDataByteSize)
            guard byteCount == 0 || audioBuffer.mData != nil else { return nil }
            guard CMBlockBufferAppendMemoryBlock(
                dataBuffer,
                memoryBlock: nil,
                length: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0
            ) == noErr else {
                return nil
            }
            if let sourceBytes = audioBuffer.mData {
                guard CMBlockBufferReplaceDataBytes(
                    with: sourceBytes,
                    blockBuffer: dataBuffer,
                    offsetIntoDestination: dataOffset,
                    dataLength: byteCount
                ) == noErr else {
                    return nil
                }
            }
            dataOffset += byteCount
        }

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}
