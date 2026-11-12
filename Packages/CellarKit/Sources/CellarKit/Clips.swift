@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

/// The last stretch of a game, held in memory as already-compressed video. Encoding is done by the
/// Mac's media engine rather than the CPU, and nothing reaches the disk until a clip is saved.
public final class ClipRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        public var seconds: Double = 30
        public var maxHeight = 1080
        public var framesPerSecond = 60
        public var bitsPerSecond = 12_000_000
        /// Bundle ID left out of the recording (Cellar's own overlay).
        public var excludedBundleID: String?
        public init() {}
    }

    private let queue = DispatchQueue(label: "cellar.clips")
    private let options: Options
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var video: [CMSampleBuffer] = []
    private var audio: [CMSampleBuffer] = []
    private var frameTimes: [CFAbsoluteTime] = []
    private var allowed = true
    private var stopHandler: (@Sendable (Error?) -> Void)?

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Frames are dropped while this is false, so an app you switch to mid-game isn't recorded.
    public func setCapturing(_ on: Bool) {
        queue.async { self.allowed = on }
    }

    /// Frames the screen really changed in the last two seconds, so about what the game is drawing.
    public func currentFrameRate() -> Double {
        queue.sync {
            let now = CFAbsoluteTimeGetCurrent()
            return Double(frameTimes.filter { now - $0 <= 2 }.count) / 2
        }
    }

    /// How much is held, for checking the pipeline.
    public func heldSamples() -> (video: Int, audio: Int) {
        queue.sync { (video.count, audio.count) }
    }

    // MARK: Start and stop

    /// `display` defaults to the main one. `onStop` is told if macOS ends the recording early.
    public func start(display displayID: CGDirectDisplayID? = nil, onStop: (@Sendable (Error?) -> Void)? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let wanted = displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
            throw CellarError("Couldn't find a display to record.")
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == options.excludedBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let size = Self.outputSize(width: display.width, height: display.height, maxHeight: options.maxHeight)

        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                                 codecType: kCMVideoCodecType_H264,
                                                 encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                                                 imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                 outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard created == noErr, let session else { throw CellarError("Couldn't start the video encoder (\(created)).") }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: options.bitsPerSecond as CFNumber)
        // A keyframe a second lets a clip start within a second of the time asked for.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: options.framesPerSecond as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        queue.sync {
            self.encoder = session
            self.stream = stream
            self.stopHandler = onStop
            self.video = []
            self.audio = []
            self.frameTimes = []
        }
        try await stream.startCapture()
    }

    public func stop() async {
        let (stream, session): (SCStream?, VTCompressionSession?) = queue.sync {
            let pair = (self.stream, self.encoder)
            self.stream = nil
            self.encoder = nil
            self.stopHandler = nil
            return pair
        }
        try? await stream?.stopCapture()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        queue.sync {
            video = []
            audio = []
            frameTimes = []
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            let handler = self.stopHandler
            self.stopHandler = nil
            handler?(error)
        }
    }

    /// Keeps even dimensions, which H.264 needs.
    static func outputSize(width: Int, height: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(maxHeight) / Double(max(height, 1)))
        let w = Int((Double(width) * scale).rounded()) & ~1
        let h = Int((Double(height) * scale).rounded()) & ~1
        return (max(w, 2), max(h, 2))
    }

    // MARK: Frames

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen: handleVideo(buffer)
        case .audio: handleAudio(buffer)
        default: break
        }
    }

    private func handleVideo(_ buffer: CMSampleBuffer) {
        guard allowed, let session = encoder else { return }
        // Idle frames (nothing on screen changed) carry no picture.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        frameTimes.append(now)
        if frameTimes.count > 300 { frameTimes.removeFirst(frameTimes.count - 300) }

        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            let boxed = UncheckedBox(sample)
            self?.queue.async { self?.keepVideo(boxed.value) }
        }
    }

    private func keepVideo(_ sample: CMSampleBuffer) {
        video.append(sample)
        let cutoff = CMSampleBufferGetPresentationTimeStamp(sample).seconds - options.seconds - 2
        Self.dropOld(&video, before: cutoff)
    }

    private func handleAudio(_ buffer: CMSampleBuffer) {
        guard allowed, let copy = Self.copyOfAudio(buffer) else { return }
        audio.append(copy)
        let cutoff = CMSampleBufferGetPresentationTimeStamp(copy).seconds - options.seconds - 2
        Self.dropOld(&audio, before: cutoff)
    }

    /// ScreenCaptureKit stops sending sound once about a second of its own buffers is being held,
    /// so what's kept has to be a copy.
    static func copyOfAudio(_ source: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(source), let data = CMSampleBufferGetDataBuffer(source) else { return nil }
        let length = CMBlockBufferGetDataLength(data)
        var block: CMBlockBuffer?
        guard length > 0,
              CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer, CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: pointer) == noErr else { return nil }
        var copy: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: CMSampleBufferGetNumSamples(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), packetDescriptions: nil, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    private static func dropOld(_ list: inout [CMSampleBuffer], before cutoff: Double) {
        guard let index = list.firstIndex(where: { CMSampleBufferGetPresentationTimeStamp($0).seconds >= cutoff }), index > 0 else { return }
        list.removeFirst(index)
    }

    // MARK: Saving

    /// Writes what's held to an MP4 at `url`. Recording carries on underneath.
    public func save(to url: URL) async throws {
        let snapshot = queue.sync { (UncheckedBox(video), UncheckedBox(audio)) }
        // A still screen sends no new pictures while the sound carries on, so "now" is the newer of the two.
        // Counting back from the last picture alone gave a clip that started silent and ran long.
        let newestSound = snapshot.1.value.last.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        let span = ClipTimeline.span(of: snapshot.0.value.map {
            ClipTimeline.Frame(time: CMSampleBufferGetPresentationTimeStamp($0).seconds, isKeyframe: Self.isKeyframe($0))
        }, seconds: options.seconds, until: newestSound)
        guard let span else { throw CellarError("Nothing to save yet. Give it a few more seconds.") }
        let frames = Array(snapshot.0.value[span])
        let start = CMSampleBufferGetPresentationTimeStamp(frames[0])
        let sounds = snapshot.1.value.filter { CMSampleBufferGetPresentationTimeStamp($0) >= start }
        try await Self.write(video: frames, audio: sounds, startingAt: start, to: url)
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// Video is copied as it was compressed; sound becomes AAC.
    static func write(video: [CMSampleBuffer], audio: [CMSampleBuffer], startingAt start: CMTime, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        guard let format = CMSampleBufferGetFormatDescription(video[0]) else { throw CellarError("The recording has no video format.") }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let first = audio.first, let hint = CMSampleBufferGetFormatDescription(first) {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else { throw writer.error ?? CellarError("Couldn't start writing the clip.") }
        writer.startSession(atSourceTime: start)
        do {
            try await append(video: video, to: videoInput, audio: audio, to: audioInput, writer: writer)
            let box = UncheckedBox(writer)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                box.value.finishWriting { done.resume() }
            }
            if writer.status != .completed { throw writer.error ?? CellarError("Couldn't finish writing the clip.") }
        } catch {
            // A full disk, say. Half a file would show in the library as a clip that can't be read.
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Feeds both tracks together: the writer stops accepting one until it has enough of the other.
    private static func append(video: [CMSampleBuffer], to videoInput: AVAssetWriterInput,
                               audio: [CMSampleBuffer], to audioInput: AVAssetWriterInput?, writer: AVAssetWriter) async throws {
        var nextVideo = 0
        var nextAudio = audioInput == nil ? audio.count : 0
        var stalledSince = Date()
        var videoFinished = false
        var audioFinished = false
        while nextVideo < video.count || nextAudio < audio.count {
            var progressed = false
            while nextVideo < video.count, videoInput.isReadyForMoreMediaData {
                guard videoInput.append(video[nextVideo]) else { throw writer.error ?? CellarError("Couldn't write the clip.") }
                nextVideo += 1
                progressed = true
            }
            if nextVideo == video.count, !videoFinished {
                videoInput.markAsFinished()
                videoFinished = true
            }
            if let audioInput {
                while nextAudio < audio.count, audioInput.isReadyForMoreMediaData {
                    guard audioInput.append(audio[nextAudio]) else { throw writer.error ?? CellarError("Couldn't write the clip.") }
                    nextAudio += 1
                    progressed = true
                }
                if nextAudio == audio.count, !audioFinished {
                    audioInput.markAsFinished()
                    audioFinished = true
                }
            }
            if writer.status == .failed { throw writer.error ?? CellarError("Couldn't write the clip.") }
            if progressed {
                stalledSince = Date()
            } else {
                if Date().timeIntervalSince(stalledSince) > 20 { throw CellarError("Writing the clip stalled.") }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        if !videoFinished { videoInput.markAsFinished() }
        if let audioInput, !audioFinished { audioInput.markAsFinished() }
    }

    // MARK: Screenshots

    /// A still of the display, without Cellar's own windows.
    public static func screenshot(to url: URL, excludedBundleID: String?, display displayID: CGDirectDisplayID? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let wanted = displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
            throw CellarError("Couldn't find a display to capture.")
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == excludedBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CellarError("Couldn't save the screenshot.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CellarError("Couldn't save the screenshot.") }
    }
}

/// `CMSampleBuffer` isn't marked Sendable, though these are never changed after they're made.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Which held frames a clip should use.
public enum ClipTimeline {
    public struct Frame: Sendable, Equatable {
        public var time: Double
        public var isKeyframe: Bool
        public init(time: Double, isKeyframe: Bool) {
            self.time = time
            self.isKeyframe = isKeyframe
        }
    }

    /// From the last keyframe at or before `seconds` ago, through the newest frame. Video can only be
    /// decoded from a keyframe, so a clip may run a little long but never starts on a broken picture.
    /// `until` is the newest sound, when that's later than the newest frame.
    public static func span(of frames: [Frame], seconds: Double, until: Double? = nil) -> Range<Int>? {
        guard let newest = frames.last?.time, let firstKey = frames.firstIndex(where: \.isKeyframe) else { return nil }
        let wanted = max(newest, until ?? newest) - seconds
        let start = frames.indices.last { frames[$0].isKeyframe && frames[$0].time <= wanted } ?? firstKey
        return start..<frames.count
    }
}

/// Saved clips and screenshots, in `~/Movies/Cellar Clips/<Game>/`.
public struct ClipItem: Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: Sendable { case video, screenshot }
    public var url: URL
    public var game: String
    public var date: Date
    public var size: Int64
    public var kind: Kind
    public var id: String { url.path }

    public init(url: URL, game: String, date: Date, size: Int64, kind: Kind) {
        self.url = url
        self.game = game
        self.date = date
        self.size = size
        self.kind = kind
    }
}

public enum ClipLibrary {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Cellar Clips", directoryHint: .isDirectory)
    }

    public static func newURL(game: String, kind: ClipItem.Kind, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safe = safeName(game)
        return folder.appending(path: safe, directoryHint: .isDirectory)
            .appending(path: "\(safe) \(formatter.string(from: date)).\(kind == .video ? "mp4" : "png")")
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        let text = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        return text.isEmpty ? "Game" : text
    }

    /// The entry for one file that's just been saved.
    public static func item(at url: URL) -> ClipItem? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        let ext = url.pathExtension.lowercased()
        guard ext == "mp4" || ext == "png", let values else { return nil }
        return ClipItem(url: url, game: url.deletingLastPathComponent().lastPathComponent, date: values.creationDate ?? Date(),
                        size: Int64(values.fileSize ?? 0), kind: ext == "mp4" ? .video : .screenshot)
    }

    /// Newest first. `game` narrows it to one game's folder.
    public static func items(game: String? = nil, root: URL = ClipLibrary.folder) -> [ClipItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let folders: [URL]
        if let game {
            folders = [root.appending(path: safeName(game), directoryHint: .isDirectory)]
        } else {
            folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        var result: [ClipItem] = []
        for folder in folders {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [] {
                let ext = file.pathExtension.lowercased()
                guard ext == "mp4" || ext == "png" else { continue }
                let values = try? file.resourceValues(forKeys: Set(keys))
                result.append(ClipItem(url: file, game: folder.lastPathComponent, date: values?.creationDate ?? .distantPast,
                                       size: Int64(values?.fileSize ?? 0), kind: ext == "mp4" ? .video : .screenshot))
            }
        }
        return result.sorted { $0.date > $1.date }
    }
}

public enum ClipEditor {
    /// Copies part of a clip to a new file without re-encoding, so it's quick and loses no quality.
    /// Video can only start on a keyframe, so a trimmed clip may begin up to a second early.
    public static func trim(_ source: URL, from start: Double, to end: Double, saveTo output: URL) async throws {
        guard end > start else { throw CellarError("Choose a longer part of the clip.") }
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CellarError("This clip can't be trimmed.")
        }
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        export.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .mp4)
    }

    /// The range for "keep the last N seconds". The whole clip if it's shorter than that.
    public static func lastPart(seconds: Double, of duration: Double) -> (start: Double, end: Double) {
        (max(duration - seconds, 0), duration)
    }

    /// The size a small copy aims for. Many chat apps limit free uploads to about this.
    public static let smallLimit = 10_000_000

    /// Re-encodes to a bitrate worked out from the clip's length, because Apple's export presets leave
    /// game footage far too big (a 63 MB clip came out at 43 MB at 640x480). Returns the size it got
    /// to, which can still be over the limit if the clip is too long for that.
    public static func makeSmall(_ source: URL, saveTo output: URL, limit: Int = ClipEditor.smallLimit) async throws -> Int {
        let length = try await AVURLAsset(url: source).load(.duration).seconds
        guard length > 0 else { throw CellarError("Couldn't read this clip.") }
        let audioRate = 96_000
        var size = 0
        // The encoder can overshoot what it's asked for, so it gets a couple more tries.
        for margin in [0.9, 0.7, 0.5] {
            let rate = max(Int(Double(limit) * 8 * margin / length) - audioRate, 300_000)
            try await encode(source, to: output, videoRate: rate, audioRate: audioRate)
            size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0, size <= limit { return size }
            if rate == 300_000 { break }
        }
        guard size > 0 else { throw CellarError("Couldn't make a small copy of this clip.") }
        return size
    }

    /// The picture height that looks best at a bitrate. Less detail at a sharper size looks worse.
    static func smallHeight(forRate rate: Int) -> Int {
        switch rate {
        case 4_000_000...: 1080
        case 1_800_000...: 720
        case 900_000...: 540
        default: 360
        }
    }

    private static func encode(_ source: URL, to output: URL, videoRate: Int, audioRate: Int) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CellarError("This clip has no video.")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let height = min(smallHeight(forRate: videoRate), Int(natural.height))
        // Video encoders need even sizes.
        let width = Int((natural.width * CGFloat(height) / natural.height / 2).rounded()) * 2
        let evenHeight = height / 2 * 2

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: evenHeight,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ] as [String: Any],
        ])
        videoIn.transform = transform
        writer.add(videoIn)

        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let audio {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioRate,
            ])
            writer.add(input)
            audioOut = output
            audioIn = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CellarError("Couldn't start making a small copy.")
        }
        writer.startSession(atSourceTime: .zero)

        // Both tracks go in from one loop, whichever is ready, so neither can hold the other up.
        // 60 frames a second wastes a small file's bits, so it keeps at most 30.
        var videoDone = false
        var audioDone = audioOut == nil
        var nextFrame = 0.0
        var stalledSince = Date()
        // A writer that has failed (a full disk) never becomes ready again, so this would wait forever.
        while !videoDone || !audioDone, writer.status == .writing, reader.status != .failed {
            var moved = false
            if !videoDone, videoIn.isReadyForMoreMediaData {
                moved = true
                if let sample = videoOut.copyNextSampleBuffer() {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if time >= nextFrame - 0.002 {
                        nextFrame = max(nextFrame + 1.0 / 30, time)
                        guard videoIn.append(sample) else { break }
                    }
                } else {
                    videoIn.markAsFinished()
                    videoDone = true
                }
            }
            if !audioDone, let audioOut, let audioIn, audioIn.isReadyForMoreMediaData {
                moved = true
                if let sample = audioOut.copyNextSampleBuffer() {
                    guard audioIn.append(sample) else { break }
                } else {
                    audioIn.markAsFinished()
                    audioDone = true
                }
            }
            if moved {
                stalledSince = Date()
            } else {
                if Date().timeIntervalSince(stalledSince) > 30 { break }
                try await Task.sleep(for: .milliseconds(3))
            }
        }
        if reader.status == .failed || writer.status == .failed || !videoDone || !audioDone {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? reader.error ?? CellarError("Couldn't make a small copy of this clip.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? CellarError("Couldn't make a small copy of this clip.")
        }
    }

    /// "Teardown 2026-11-02.mp4" becomes "Teardown 2026-11-02 trimmed.mp4", then "trimmed 2" and on.
    public static func copyURL(for source: URL, suffix: String) -> URL {
        let folder = source.deletingLastPathComponent()
        var name = source.deletingPathExtension().lastPathComponent
        // Copies of copies don't pile up their names.
        for existing in [" trimmed", " small"] where name.hasSuffix(existing) { name.removeLast(existing.count) }
        var candidate = folder.appending(path: "\(name) \(suffix).\(source.pathExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(name) \(suffix) \(number).\(source.pathExtension)")
            number += 1
        }
        return candidate
    }
}
