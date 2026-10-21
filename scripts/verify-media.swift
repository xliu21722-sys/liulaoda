import AppKit
import AVFoundation
import AudioToolbox
import CoreVideo

@main struct VerifyMedia {
    static let unit=CGRect(x:0,y:0,width:1,height:1)
    static let crop=CGRect(x:0.125,y:0.1,width:0.5,height:0.5)
    static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TutorialCapture-MediaCheck-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("source.mp4")
        try await makeClip(at:source)
        let original=try Data(contentsOf:source)
        let unchanged=root.appendingPathComponent("unchanged.mp4")
        try await export(source,to:unchanged,start:0,end:1,crop:unit)
        try check(try Data(contentsOf:unchanged)==original,"Untouched save recompressed the recording")
        let trimmed=root.appendingPathComponent("trimmed.mp4")
        try await export(source,to:trimmed,start:0.215,end:0.765,crop:unit)
        try await verify(trimmed,size:CGSize(width:640,height:360),seconds:1.1)
        let cropped=root.appendingPathComponent("cropped.mp4")
        try await export(source,to:cropped,start:0,end:1,crop:crop)
        try await verify(cropped,size:CGSize(width:320,height:180),seconds:2)
        let combined=root.appendingPathComponent("combined.mp4")
        try await export(source,to:combined,start:0.215,end:0.765,crop:crop)
        try await verify(combined,size:CGSize(width:320,height:180),seconds:1.1)
        let reference=try await image(source,at:0.6)
        let expected=reference.cropping(to:CGRect(x:80,y:36,width:320,height:180))!
        let cropPSNR=try psnr(expected,try await image(cropped,at:0.6))
        let trimPSNR=try psnr(try await image(source,at:13.0/30),try await image(trimmed,at:0.01))
        print("crop_PSNR=\(cropPSNR) trim_PSNR=\(trimPSNR)")
        try check(cropPSNR>32,"Incorrect crop position or quality loss")
        try check(trimPSNR>32,"Incorrect trim frame or quality loss")
        let occupied=root.appendingPathComponent("occupied.mp4"), marker=Data("keep existing asset".utf8)
        try marker.write(to:occupied)
        var rejected=false
        do { try await export(source,to:occupied,start:0.1,end:0.9,crop:unit) } catch { rejected=true }
        try check(rejected,"Export overwrote an existing file")
        try check(try Data(contentsOf:occupied)==marker,"Existing asset changed")
        try check(try Data(contentsOf:source)==original,"Source was lost or modified")
        print("PASS byte_identical=true trim=1.10s crop=320x180 audio_tracks=2 overwrite_refused=true source_preserved=true")
    }
    static func verify(_ url:URL,size:CGSize,seconds:Double) async throws {
        let asset=AVURLAsset(url:url), duration=CMTimeGetSeconds(try await AVURLAsset(url:url).load(.duration))
        let video=try await asset.loadTracks(withMediaType:.video), audio=try await asset.loadTracks(withMediaType:.audio)
        try check(abs(duration-seconds)<0.06,"Unexpected duration \(duration)")
        try check(try await video[0].load(.naturalSize)==size,"Resolution changed unexpectedly")
        try check(audio.count==2,"Microphone or computer audio track lost")
        for track in audio { try check(CMTimeGetSeconds(try await track.load(.timeRange).duration)>seconds-0.08,"Audio duration incorrect") }
    }
    static func makeClip(at url:URL) async throws {
        let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:CaptureQuality.h264Settings(width:640,height:360))
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:640,kCVPixelBufferHeightKey as String:360,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        writer.add(input)
        var audios:[AVAssetWriterInput]=[]
        for _ in 0..<2 {
            let audio=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:128000])
            writer.add(audio); audios.append(audio)
        }
        try check(writer.startWriting(),"Writer failed to start"); writer.startSession(atSourceTime:.zero)
        for (index,audio) in audios.enumerated() {
            while !audio.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(2)) }
            try check(audio.append(try tone(index==0 ? 440:880)),"Audio generation failed")
            audio.markAsFinished()
        }
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(2)) }
            var pixel:CVPixelBuffer?
            guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel)==kCVReturnSuccess,let px=pixel else { throw error("Pixel buffer failed") }
            CVPixelBufferLockBaseAddress(px,[])
            let base=CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to:UInt8.self), stride=CVPixelBufferGetBytesPerRow(px)
            for y in 0..<360 { for x in 0..<640 {
                let p=y*stride+x*4
                base[p]=UInt8(60+(x/3+i)%140); base[p+1]=UInt8(30+y/2); base[p+2]=180; base[p+3]=255
                if x>300,x<380 { let v:UInt8=x%2==0 ? 20:230; base[p]=v; base[p+1]=v; base[p+2]=v }
                if x>=i*3,x<i*3+24,y>250 { base[p]=0; base[p+1]=0; base[p+2]=250 }
            } }
            CVPixelBufferUnlockBaseAddress(px,[])
            try check(adaptor.append(px,withPresentationTime:CMTime(value:Int64(i),timescale:30)),"Video append failed")
        }
        input.markAsFinished(); await writer.finishWriting()
        try check(writer.status == .completed,"Synthetic recording failed")
    }
    static func tone(_ frequency:Double) throws -> CMSampleBuffer {
        var asbd=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,mBytesPerPacket:2,mFramesPerPacket:1,mBytesPerFrame:2,mChannelsPerFrame:1,mBitsPerChannel:16,mReserved:0)
        var format:CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format)==noErr,"Audio format")
        let samples=(0..<96000).map { Int16(sin(2 * .pi * frequency * Double($0)/48000)*5000) }, length=96000*2
        var block:CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:length,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:length,flags:0,blockBufferOut:&block)==noErr,"Audio memory")
        let status=samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:length) }
        try check(status==noErr,"Audio copy")
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:48000),presentationTimeStamp:.zero,decodeTimeStamp:.invalid), size=2
        var buffer:CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,sampleCount:samples.count,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&buffer)==noErr,"Audio sample")
        return buffer!
    }
    static func image(_ url:URL,at seconds:Double) async throws -> CGImage {
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url)); generator.appliesPreferredTrackTransform=true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at:CMTime(seconds:seconds,preferredTimescale:60000)).image
    }
    static func psnr(_ a:CGImage,_ b:CGImage) throws -> Double {
        try check(a.width==b.width && a.height==b.height,"Frame dimensions differ")
        func bytes(_ image:CGImage) -> [UInt8] {
            var data=[UInt8](repeating:0,count:image.width*image.height*4)
            data.withUnsafeMutableBytes { memory in
                let c=CGContext(data:memory.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            }; return data
        }
        let x=bytes(a),y=bytes(b)
        var mse=0.0
        for i in x.indices where i%4 != 3 { let d=Double(x[i])-Double(y[i]); mse+=d*d }
        mse/=Double(a.width*a.height*3)
        return mse==0 ? .infinity : 10*log10(255*255/mse)
    }
    static func export(_ source:URL,to:URL,start:Double,end:Double,crop:CGRect) async throws {
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            VideoEditor.export(source:source,to:to,start:start,end:end,cropRect:crop) { if let e=$0 { c.resume(throwing:e) } else { c.resume() } }
        }
    }
    static func check(_ value:Bool,_ text:String) throws { if !value { throw error(text) } }
    static func error(_ text:String) -> NSError { NSError(domain:"MediaVerification",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
}
