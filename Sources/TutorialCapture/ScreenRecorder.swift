import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia

enum CaptureQuality {
    static func pixelScale(filter: SCContentFilter, screen: NSScreen) -> CGFloat {
        let scale = CGFloat(filter.pointPixelScale)
        return scale.isFinite && scale > 0 ? scale : screen.backingScaleFactor
    }

    static func evenDimension(_ value: CGFloat) -> Int { max(2, Int(value.rounded()) / 2 * 2) }

    static func h264Settings(width: Int, height: Int, frameRate: Double = 30) -> [String: Any] {
        // Keep fine UI text readable at the native capture size. AVC's default
        // rate control favors small files and is insufficient for Retina text.
        let bitRate = max(8_000_000, width * height * 6)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2
            ]
        ]
    }
}

enum ScreenCapture {
    static func snapshot(region: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        guard let screen=NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }),
              let display=content.displays.first(where:{$0.displayID == displayID}) else { throw ScreenRecorder.CaptureError.noDisplay }
        let excluded=content.applications.filter{$0.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "")}
        let filter=SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[])
        let scale=CaptureQuality.pixelScale(filter:filter, screen:screen); let config=SCStreamConfiguration()
        config.captureResolution = .best
        config.sourceRect=region; config.width=max(1,Int((region.width*scale).rounded())); config.height=max(1,Int((region.height*scale).rounded()))
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter:filter,configuration:config) { image,error in
                if let image { continuation.resume(returning:image) }
                else { continuation.resume(throwing:error ?? ScreenRecorder.CaptureError.noFrames) }
            }
        }
    }
}

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var firstPTS: CMTime?
    private var finishing=false
    private var completion: ((URL?,Error?)->Void)?
    private var onStart: ((Result<Void,Error>)->Void)?
    private var appendError: Error?
    private var didReportAppendError = false
    private let queue=DispatchQueue(label:"TutorialCapture.screen.samples")
    private var onStatus:((String)->Void)?
    private var displayID: CGDirectDisplayID?
    private var spaceObserver: NSObjectProtocol?
    private var spaceOperationTask: Task<Void, Never>?
    private var streamConfiguration: SCStreamConfiguration?
    private var currentFilter: SCContentFilter?
    private var capturesSystemAudio = false
    private var capturesMicrophone = false

    func start(region:CGRect,displayID:CGDirectDisplayID,contentTask:Task<SCShareableContent,Error>? = nil,systemAudio:Bool,microphone:Bool,onStart:@escaping(Result<Void,Error>)->Void,onStatus:@escaping(String)->Void) {
        self.onStart=onStart
        self.onStatus=onStatus
        self.displayID=displayID
        Task {
            do {
                // Prefetch while the user chooses the region so recording starts
                // without another visible pause. The filter is display-wide; we
                // refresh it on every Space change so it follows the active desktop.
                let content: SCShareableContent
                if let contentTask {
                    content = try await contentTask.value
                } else {
                    content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                }
                guard let screen=NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                }), let display=content.displays.first(where:{$0.displayID == displayID}) else { throw CaptureError.noDisplay }
                let bundle=Bundle.main.bundleIdentifier ?? ""
                let excluded=content.applications.filter{$0.bundleIdentifier == bundle}
                let filter=SCContentFilter(display:display,excludingApplications:excluded, exceptingWindows:[])
                self.currentFilter = filter
                let scale=CaptureQuality.pixelScale(filter:filter, screen:screen)
                let config=SCStreamConfiguration()
                config.captureResolution = .best
                config.sourceRect=CGRect(x:region.minX,y:region.minY,width:region.width,height:region.height)
                config.width=CaptureQuality.evenDimension(region.width*scale); config.height=CaptureQuality.evenDimension(region.height*scale)
                config.minimumFrameInterval=CMTime(value:1,timescale:30); config.queueDepth=6
                config.capturesAudio=systemAudio; config.captureMicrophone=microphone
                config.sampleRate=48000; config.channelCount=2
                config.showsCursor=true
                self.streamConfiguration = config
                self.capturesSystemAudio = systemAudio
                self.capturesMicrophone = microphone
                let temp=FileManager.default.temporaryDirectory.appendingPathComponent("TutorialCapture-\(UUID().uuidString).mp4")
                self.outputURL=temp
                let w=try AVAssetWriter(outputURL:temp,fileType:.mp4)
                let vi=AVAssetWriterInput(mediaType:.video,outputSettings:CaptureQuality.h264Settings(width:config.width,height:config.height))
                vi.expectsMediaDataInRealTime=true
                guard w.canAdd(vi) else { throw CaptureError.writerInput }; w.add(vi)
                if systemAudio {
                    let ai=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:128000])
                    ai.expectsMediaDataInRealTime=true; if w.canAdd(ai) { w.add(ai); audioInput=ai }
                }
                if microphone {
                    let mi=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:96000])
                    mi.expectsMediaDataInRealTime=true; if w.canAdd(mi) { w.add(mi); microphoneInput=mi }
                }
                writer=w; videoInput=vi
                let s=try makeStream(filter:filter, configuration:config)
                self.stream=s; try await s.startCapture()
                observeSpaceChanges()
                self.onStart?(.success(()))
                if microphone { onStatus("录制中；麦克风授权由 macOS 管理") }
            } catch {
                onStatus("启动录制失败：\(error.localizedDescription)")
                self.onStart?(.failure(error))
            }
        }
    }
    func stop(completion:@escaping(URL?,Error?)->Void) {
        self.completion=completion
        finishing = true
        removeSpaceObserver()
        let pendingSpaceOperation = spaceOperationTask
        Task {
            await pendingSpaceOperation?.value
            do { try await stream?.stopCapture() }
            catch { self.onStatus?("停止采集时出现问题：\(error.localizedDescription)") }
            queue.async {
                self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished(); self.microphoneInput?.markAsFinished()
                guard let writer=self.writer else { self.completion?(nil,CaptureError.noFrames); return }
                writer.finishWriting {
                    let error=self.appendError ?? writer.error
                    guard writer.status == .completed, error == nil else {
                        self.completion?(nil,error ?? CaptureError.writerFailed)
                        return
                    }
                    self.completion?(self.outputURL,nil)
                }
            }
        }
    }
    private func observeSpaceChanges() {
        removeSpaceObserver()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refreshContentFilterAfterSpaceChange()
        }
    }
    private func removeSpaceObserver() {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }
    private func refreshContentFilterAfterSpaceChange() {
        guard !finishing else { return }
        let previous = spaceOperationTask
        spaceOperationTask = Task { [weak self] in
            await previous?.value
            await self?.restartStreamForActiveSpace()
        }
    }
    private func restartStreamForActiveSpace() async {
        guard !finishing, let oldStream = stream, let displayID, let configuration = streamConfiguration else { return }
        var filterToUse = currentFilter
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                let bundle = Bundle.main.bundleIdentifier ?? ""
                let excluded = content.applications.filter { $0.bundleIdentifier == bundle }
                filterToUse = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            }
        } catch {
            onStatus?("切换桌面后重新读取屏幕失败，正在沿用原显示器继续录制：\(error.localizedDescription)")
        }
        guard !finishing, let filter = filterToUse else { return }
        try? await oldStream.stopCapture()
        queue.sync {} // Drain samples from the previous Space before reconnecting.
        guard !finishing else { return }
        do {
            let replacement = try makeStream(filter: filter, configuration: configuration)
            stream = replacement
            try await replacement.startCapture()
            currentFilter = filter
            onStatus?("已切换桌面，录制已继续")
        } catch {
            stream = nil
            onStatus?("切换桌面后恢复录制失败：\(error.localizedDescription)")
        }
    }
    private func makeStream(filter: SCContentFilter, configuration: SCStreamConfiguration) throws -> SCStream {
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if capturesSystemAudio { try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if capturesMicrophone { try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        return newStream
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), !finishing, let writer else { return }
        if type == .screen && !hasCompleteScreenFrame(sampleBuffer) { return }
        if firstPTS == nil {
            let pts=CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, writer.startWriting() else {
                appendError=writer.error ?? CaptureError.writerFailed
                if !didReportAppendError { didReportAppendError=true; onStatus?("MP4 写入器启动失败：\(appendError!.localizedDescription)") }
                return
            }
            firstPTS=pts
            writer.startSession(atSourceTime:pts)
        }
        switch type {
        case .screen: append(sampleBuffer, to:videoInput, writer:writer)
        case .audio: append(sampleBuffer, to:audioInput, writer:writer)
        case .microphone: append(sampleBuffer, to:microphoneInput, writer:writer)
        default: break
        }
    }
    private func hasCompleteScreenFrame(_ sampleBuffer:CMSampleBuffer)->Bool {
        guard let list=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let attachments=list.first,
              let raw=attachments[SCStreamFrameInfo.status] as? Int,
              let status=SCFrameStatus(rawValue:raw) else { return false }
        return status == .complete
    }
    private func append(_ sampleBuffer:CMSampleBuffer,to input:AVAssetWriterInput?,writer:AVAssetWriter) {
        guard let input, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            appendError=writer.error ?? CaptureError.writerFailed
            if !didReportAppendError { didReportAppendError=true; onStatus?("MP4 写入失败：\(appendError!.localizedDescription)") }
        }
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) { onStatus?("录制中断：\(error.localizedDescription)") }
    enum CaptureError:LocalizedError { case noDisplay,writerInput,noFrames,writerFailed; var errorDescription:String? { switch self {case .noDisplay:return "找不到屏幕";case .writerInput:return "无法初始化 MP4 编码器";case .noFrames:return "没有收到有效视频画面";case .writerFailed:return "MP4 写入器未能完成文件"} } }
}

enum VideoEditor {
    static func export(source:URL,to:URL,start:Double,end:Double,cropRect:CGRect,completion:@escaping(Error?)->Void) {
        Task {
            do {
                try await render(source:source, to:to, start:start, end:end, cropRect:cropRect)
                completion(nil)
            } catch { completion(error) }
        }
    }

    private static func render(source:URL, to:URL, start:Double, end:Double, cropRect:CGRect) async throws {
        let asset = AVURLAsset(url:source)
        let duration = try await asset.load(.duration)
        let full = CMTimeGetSeconds(duration)
        guard full.isFinite, full > 0, start.isFinite, end.isFinite else { throw failure("视频时长无效") }
        let unit = CGRect(x:0,y:0,width:1,height:1)
        let crop = cropRect.intersection(unit)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { throw failure("画面裁剪范围无效") }
        if start <= 0, end >= 1, crop == unit {
            // Saving an untouched recording must not introduce a second generation
            // of lossy compression. copyItem also refuses to overwrite old assets.
            try FileManager.default.copyItem(at:source,to:to)
            return
        }
        let a = max(0,min(full,start*full)), b = max(0,min(full,end*full))
        guard b > a else { throw failure("片段结束位置必须晚于开始位置") }
        let range = CMTimeRange(start:CMTime(seconds:a,preferredTimescale:60000),duration:CMTime(seconds:b-a,preferredTimescale:60000))
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw failure("视频没有画面轨道") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFPS = Double(try await track.load(.nominalFrameRate))
        let fps = nominalFPS.isFinite && nominalFPS > 0 ? nominalFPS : 30
        // Normalize the selected source range to zero before compositing. Screen
        // recordings can contain edit-list offsets across Space transitions;
        // using that range directly with a video-composition reader can trim twice.
        let timeline = AVMutableComposition()
        guard let videoTrack = timeline.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw failure("无法创建视频片段") }
        try videoTrack.insertTimeRange(range,of:track,at:.zero)
        var audioTracks: [AVCompositionTrack] = []
        for audio in try await asset.loadTracks(withMediaType:.audio) {
            guard let part = timeline.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw failure("无法创建声音片段") }
            let available = CMTimeRangeGetIntersection(range,otherRange:try await audio.load(.timeRange))
            if available.duration > .zero {
                try part.insertTimeRange(available,of:audio,at:available.start-range.start)
                audioTracks.append(part)
            }
        }
        let reader = try AVAssetReader(asset:timeline)
        reader.timeRange = CMTimeRange(start:.zero,duration:range.duration)
        var width = CaptureQuality.evenDimension(abs(natural.width))
        var height = CaptureQuality.evenDimension(abs(natural.height))
        let pixelSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
        let videoOutput: AVAssetReaderOutput
        if crop != unit {
            let bounds = CGRect(origin:.zero,size:natural).applying(transform).standardized
            let left = crop.minX*bounds.width
            let top = crop.minY*bounds.height
            width = CaptureQuality.evenDimension(crop.width*bounds.width)
            height = CaptureQuality.evenDimension(crop.height*bounds.height)
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width:width,height:height)
            composition.frameDuration = CMTime(seconds:1/fps,preferredTimescale:60000)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start:.zero,duration:range.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack:videoTrack)
            layer.setTransform(transform.concatenating(CGAffineTransform(translationX:-bounds.minX-left,y:-bounds.minY-top)),at:.zero)
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]
            let output = AVAssetReaderVideoCompositionOutput(videoTracks:[videoTrack],videoSettings:pixelSettings)
            output.videoComposition = composition
            videoOutput = output
        } else {
            videoOutput = AVAssetReaderTrackOutput(track:videoTrack,outputSettings:pixelSettings)
        }
        videoOutput.alwaysCopiesSampleData = false
        let writer = try AVAssetWriter(outputURL:to,fileType:.mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType:.video,outputSettings:CaptureQuality.h264Settings(width:width,height:height,frameRate:fps))
        if crop == unit { videoInput.transform = transform }
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw failure("无法初始化高清导出器") }
        reader.add(videoOutput); writer.add(videoInput)
        var pipes = [ExportPipe(output:videoOutput,input:videoInput)]
        // Retain both computer sound and microphone tracks without another AAC encode.
        for audioTrack in audioTracks {
            guard let format = try await audioTrack.load(.formatDescriptions).first else { throw failure("无法读取声音轨道") }
            let output = AVAssetReaderTrackOutput(track:audioTrack,outputSettings:nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType:.audio,outputSettings:nil,sourceFormatHint:format)
            guard reader.canAdd(output), writer.canAdd(input) else { throw failure("无法保留声音轨道") }
            reader.add(output); writer.add(input)
            pipes.append(ExportPipe(output:output,input:input))
        }
        do {
            guard writer.startWriting() else { throw writer.error ?? failure("无法开始写入 MP4") }
            writer.startSession(atSourceTime:.zero)
            guard reader.startReading() else { throw reader.error ?? failure("无法读取原片") }
            try await withThrowingTaskGroup(of:Void.self) { group in
                for pipe in pipes {
                    group.addTask { try await transfer(pipe, reader:reader, writer:writer) }
                }
                do { while try await group.next() != nil {} }
                catch { group.cancelAll(); reader.cancelReading(); throw error }
            }
            writer.endSession(atSourceTime:range.duration)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? failure("MP4 导出未完成") }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }

    private struct ExportPipe: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    private static func transfer(_ pipe:ExportPipe, reader:AVAssetReader, writer:AVAssetWriter) async throws {
        defer { pipe.input.markAsFinished() }
        while true {
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? failure("读取原片失败") }
            guard writer.status == .writing else { throw writer.error ?? failure("写入导出文件失败") }
            if !pipe.input.isReadyForMoreMediaData {
                try await Task.sleep(for:.milliseconds(2))
                continue
            }
            guard let sample = autoreleasepool(invoking:{ pipe.output.copyNextSampleBuffer() }) else { return }
            guard pipe.input.append(sample) else { throw writer.error ?? failure("写入视频或声音失败") }
        }
    }

    private static func failure(_ message:String) -> NSError {
        NSError(domain:"TutorialCapture.Export",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }
}
