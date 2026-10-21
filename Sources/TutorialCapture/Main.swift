import SwiftUI
import AppKit
import AVKit
import ScreenCaptureKit

@main
struct TutorialCaptureApp: App {
    @StateObject private var model = CaptureModel()
    init() {}
    var body: some Scene {
        WindowGroup("刘老大") { ContentView().environmentObject(model).frame(minWidth: 560, minHeight: 400) }
            .defaultSize(width: 780, height: 520)
        MenuBarExtra("刘老大", systemImage: "record.circle") {
            MenuBarCaptureControls(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarCaptureControls: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        Button("截屏", systemImage: "camera") {
            model.captureScreenshot()
        }
        .disabled(model.isRecording || model.isStartingRecording || model.isChoosingRegion || model.isProcessingPreview)

        Button(model.isRecording ? "结束录屏" : "录屏", systemImage: model.isRecording ? "stop.fill" : "record.circle") {
            if model.isRecording {
                if !model.isQuickRecording { model.stopRecording() }
            } else {
                model.startRecording()
            }
        }
        .disabled(model.isStartingRecording || model.isQuickRecording || model.isChoosingRegion || model.isProcessingPreview)

        Button(model.isRecording && model.isQuickRecording ? "结束快速录屏" : "快速录屏", systemImage: model.isRecording && model.isQuickRecording ? "stop.fill" : "bolt.fill") {
            if model.isRecording {
                if model.isQuickRecording { model.stopRecording() }
            } else {
                model.startRecording(quickSave: true)
            }
        }
        .disabled(model.isStartingRecording || model.isChoosingRegion || model.isProcessingPreview || (model.isRecording && !model.isQuickRecording))

        Divider()
        Button("打开刘老大") { model.showMainWindow() }
    }
}

private final class MainWindowRegistry {
    static let shared = MainWindowRegistry()
    weak var window: NSWindow?
}

@MainActor private final class CapturePreviewWindowRegistry {
    static let shared = CapturePreviewWindowRegistry()
    var window: NSWindow?
}

// A preview must join the current Space without activating a hidden main window
// on another desktop. It stays at normal window level and yields to other apps.
private final class CapturePreviewPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal
        isFloatingPanel = false
        hidesOnDeactivate = false
        canHide = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ClipSegment: Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
}

enum CaptureSaveDestination: String, CaseIterable, Identifiable {
    case project, desktop, eagle
    var id: String { rawValue }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case region, fullScreen
    var id: String { rawValue }
}

@MainActor final class CaptureModel: ObservableObject {
    @Published var projectURL: URL?
    @Published var saveDestination: CaptureSaveDestination = CaptureSaveDestination(rawValue: UserDefaults.standard.string(forKey: "saveDestination") ?? "") ?? (UserDefaults.standard.bool(forKey: "saveToEagle") ? .eagle : .project) {
        didSet { UserDefaults.standard.set(saveDestination.rawValue, forKey: "saveDestination") }
    }
    var saveToEagle: Bool { saveDestination == .eagle }
    var saveToDesktop: Bool { saveDestination == .desktop }
    @Published var captureMode: CaptureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "") ?? .region {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    @Published var eagleFolderID: String? {
        didSet { UserDefaults.standard.set(eagleFolderID, forKey: "eagleFolderID") }
    }
    @Published var eagleFolderPath: String? {
        didSet { UserDefaults.standard.set(eagleFolderPath, forKey: "eagleFolderPath") }
    }
    @Published var eagleFolders: [EagleFolderOption] = []
    @Published var showEagleFolderPicker = false
    @Published var isLoadingEagleFolders = false
    @Published var isSaving = false
    @Published var isCopying = false
    var isProcessingPreview: Bool { isSaving || isCopying }
    @Published var region: CGRect?
    @Published var previewImage: NSImage?
    @Published var previewVideo: URL?
    @Published var isRecording = false
    @Published var isStartingRecording = false
    @Published var isChoosingRegion = false
    @Published var isQuickRecording = false
    @Published var micOn = false
    @Published var systemOn = false
    @Published var purpose = ""
    @Published var status = "先选择本期视频的项目文件夹"
    @Published var trimStart = 0.0
    @Published var trimEnd = 1.0
    @Published var videoDuration = 0.0
    @Published var currentVideoTime = 0.0
    @Published var clipSegments: [ClipSegment] = []
    @Published var videoSize = CGSize(width: 16, height: 9)
    @Published var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var timelineThumbnails:[NSImage] = []
    @Published var videoIsPlaying = false
    @Published var pendingURL: URL?
    @Published var mediaType = ""
    @Published var showPreview = false
    @Published var confirmRecording = false
    @Published var savedItems:[URL] = []
    @Published var isSavedPreview = false
    @Published var currentSavedURL:URL?
    @Published var videoPlayer:AVPlayer?
    private var recorder: ScreenRecorder?
    private var recordingOverlay: RecordingOverlayController?
    private var recoveryWindow: NSWindow?
    private var capturePreviewWindow: NSWindow?
    private var quickSaveRequested = false
    private var playbackObserver:Any?
    private var recordingContentTask: Task<SCShareableContent, Error>?

    init() {
        if let p = UserDefaults.standard.string(forKey: "projectURL") { projectURL = URL(fileURLWithPath: p) }
        eagleFolderID = UserDefaults.standard.string(forKey: "eagleFolderID")
        eagleFolderPath = UserDefaults.standard.string(forKey: "eagleFolderPath")
        if let x = UserDefaults.standard.object(forKey: "regionX") as? Double,
           let y = UserDefaults.standard.object(forKey: "regionY") as? Double,
           let w = UserDefaults.standard.object(forKey: "regionW") as? Double,
           let h = UserDefaults.standard.object(forKey: "regionH") as? Double { region = CGRect(x:x,y:y,width:w,height:h) }
        if saveToDesktop { status = "保存位置：桌面" }
        else if saveToEagle { status = eagleFolderPath.map { "保存位置：Eagle / \($0)" } ?? "请选择 Eagle 保存文件夹" }
        else if let projectURL { status="项目位置：\(projectURL.lastPathComponent)" }
        refreshSaved()
    }
    func chooseProject() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "选择此期视频文件夹"; p.message = "选择或新建一个文件夹，截图和录屏都会保存到这里。"
        if p.runModal() == .OK, let u = p.url { projectURL = u; saveDestination = .project; UserDefaults.standard.set(u.path, forKey:"projectURL"); refreshSaved(); status = "项目位置：\(u.lastPathComponent)" }
    }
    func selectProjectDestination() { saveDestination = .project; chooseProject() }
    func selectDesktop() { saveDestination = .desktop; refreshSaved(); status = "保存位置：桌面" }
    func selectEagleDestination() { saveDestination = .eagle; chooseEagleFolder() }
    func chooseEagleFolder() {
        isLoadingEagleFolders = true
        status = "正在连接 Eagle 并读取文件夹…"
        Task {
            do {
                eagleFolders = try await EagleAPI.folders()
                isLoadingEagleFolders = false
                showEagleFolderPicker = true
                status = eagleFolders.isEmpty ? "Eagle 素材库中还没有文件夹。" : "请选择 Eagle 中的保存文件夹。"
            } catch {
                isLoadingEagleFolders = false
                status = error.localizedDescription
            }
        }
    }
    func selectEagleFolder(_ folder: EagleFolderOption) {
        eagleFolderID = folder.id
        eagleFolderPath = folder.path
        saveDestination = .eagle
        showEagleFolderPicker = false
        status = "保存位置：Eagle / \(folder.path)"
    }
    func refreshSaved() {
        guard !saveToEagle else { savedItems=[]; return }
        let folder = saveToDesktop ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first : projectURL
        guard let folder else { savedItems=[]; return }
        savedItems=((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter{["png","mp4"].contains($0.pathExtension.lowercased())}.sorted{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}
    }
    func previewSaved(_ url:URL) {
        stopVideoPlayer()
        isSavedPreview=true; currentSavedURL=url; pendingURL=nil; mediaType="saved"; purpose=""
        previewImage=url.pathExtension.lowercased()=="png" ? NSImage(contentsOf:url):nil
        previewVideo=url.pathExtension.lowercased()=="mp4" ? url:nil
        showPreview=true; status="正在预览已保存素材"
        if let video=previewVideo { loadVideo(video,makeTrimPreview:false) }
    }
    func revealFile(_ url:URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func showMainWindow() {
        if showPreview {
            showCapturePreviewWindow()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            var window = MainWindowRegistry.shared.window
                ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "TutorialCapture.MainWindow" })
            if window == nil {
                let root = ContentView().environmentObject(self).frame(minWidth: 560, minHeight: 400)
                let created = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 780, height: 520),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                created.identifier = NSUserInterfaceItemIdentifier("TutorialCapture.MainWindow")
                created.title = "刘老大"
                created.isReleasedWhenClosed = false
                created.titleVisibility = .visible
                created.contentView = NSHostingView(rootView: root)
                created.level = .normal
                created.center()
                self.recoveryWindow = created
                MainWindowRegistry.shared.window = created
                window = created
            }
            guard let window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
    private func showCapturePreviewWindow() {
        guard showPreview else { return }
        DispatchQueue.main.async {
            let window: NSWindow
            if let existing = self.capturePreviewWindow {
                window = existing
            } else {
                let created = CapturePreviewPanel(contentRect: CGRect(x: 0, y: 0, width: 760, height: self.mediaType == "png" ? 440 : 760))
                created.identifier = NSUserInterfaceItemIdentifier("TutorialCapture.PreviewWindow")
                created.title = self.mediaType == "png" ? "截图预览 - 刘老大" : "录屏预览 - 刘老大"
                created.isReleasedWhenClosed = false
                created.contentView = NSHostingView(rootView: ContentView(isPreviewWindow: true).environmentObject(self))
                created.level = .normal
                self.capturePreviewWindow = created
                CapturePreviewWindowRegistry.shared.window = created
                window = created
            }
            window.title = self.mediaType == "png" ? "截图预览 - 刘老大" : "录屏预览 - 刘老大"
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
            if let screen = self.captureScreenAtPointer() {
                let visible = screen.visibleFrame
                var frame = window.frame
                frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
                window.setFrame(frame, display: false)
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
    private func hideMainWindow() {
        MainWindowRegistry.shared.window?.orderOut(nil)
        capturePreviewWindow?.orderOut(nil)
    }
    func leaveSavedPreview() { stopVideoPlayer(); showPreview=false; isSavedPreview=false; currentSavedURL=nil; previewVideo=nil; previewImage=nil; status="素材列表已更新"; hideMainWindow() }
    func selectRegionMode() { captureMode = .region; status = "已选择框选模式；开始后再拖动选择区域。" }
    func selectFullScreenMode() { captureMode = .fullScreen; status = "已选择全屏模式。" }
    private func captureScreenAtPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
            return screen
        }
        if let windowScreen = MainWindowRegistry.shared.window?.screen {
            return windowScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
    func captureScreenshot(reselect: Bool = false) {
        guard !isChoosingRegion, !isStartingRecording, !isRecording, !isProcessingPreview else { return }
        guard let screen = captureScreenAtPointer() else { status = "没有找到可用屏幕"; showMainWindow(); return }
        if captureMode == .fullScreen && !reselect {
            captureScreenshot(in: CGRect(origin: .zero, size: screen.frame.size), on: screen)
            return
        }
        hideMainWindow()
        isChoosingRegion = true
        RegionPicker.show(on: screen) { [weak self] selectedRegion in
            guard let self else { return }
            self.isChoosingRegion = false
            guard let selectedRegion else { self.status = "已取消截图"; self.showMainWindow(); return }
            self.captureScreenshot(in: selectedRegion, on: screen)
        }
    }
    private func captureScreenshot(in selected: CGRect, on screen: NSScreen) {
        hideMainWindow()
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        Task {
            do {
                guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw ScreenRecorder.CaptureError.noDisplay }
                let image=try await ScreenCapture.snapshot(region:selected, displayID:displayNumber.uint32Value)
                let rep=NSBitmapImageRep(cgImage:image)
                guard let data=rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"TutorialCapture",code:10,userInfo:[NSLocalizedDescriptionKey:"无法生成 PNG"]) }
                let temp=FileManager.default.temporaryDirectory.appendingPathComponent("TutorialCapture-\(UUID().uuidString).png")
                try data.write(to:temp,options:.atomic)
                self.pendingURL=temp; self.previewImage=NSImage(cgImage:image,size:.zero); self.mediaType="png"; self.showPreview=true; self.status="截图预览：确认后才会保存"; self.showCapturePreviewWindow()
            }
            catch { self.status="截图失败：\(error.localizedDescription)。请在系统设置中允许屏幕录制后重试。"; self.showMainWindow() }
        }
    }
    func startRecording(quickSave: Bool = false) {
        guard !isChoosingRegion, !isStartingRecording, !isRecording, !isProcessingPreview else { return }
        if quickSave && showPreview {
            status = "请先处理或丢弃当前预览，再开始快速录屏。"
            return
        }
        if saveToEagle {
            guard eagleFolderID != nil else { chooseEagleFolder(); return }
        } else if !saveToDesktop && projectURL == nil { chooseProject(); return }
        guard let screen=captureScreenAtPointer() else { status="没有找到可用屏幕"; return }
        guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { status="无法识别当前显示器"; return }
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)
        quickSaveRequested = quickSave
        // Enumerate capture content while the user is choosing the region to
        // avoid adding delay after mouse-up. The display filter captures the
        // active desktop and is refreshed by ScreenRecorder when Spaces change.
        recordingContentTask = Task(priority: .userInitiated) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        hideMainWindow()
        let previousRegion: CGRect? = captureMode == .fullScreen
            ? CGRect(origin: .zero, size: screen.frame.size)
            : rememberedRegion(on: screen)
        status = previousRegion == nil
            ? "拖动框选录制区域；松开后立即开始"
            : (quickSave ? "请点击蓝色框确认快速录制，或拖动框选新区域" : "点击上次选区立即录制，或拖动框选新区域")
        isChoosingRegion = true
        RecordingRegionPicker.show(on:screen,previousRegion:previousRegion) { [weak self] selectedRegion in
            guard let self else { return }
            self.isChoosingRegion = false
            guard let selectedRegion else { self.quickSaveRequested = false; self.isQuickRecording = false; self.status="已取消录制；选区和项目保留"; self.showMainWindow(); return }
            if self.captureMode == .region {
                self.region=selectedRegion
                UserDefaults.standard.set(selectedRegion.origin.x, forKey:"regionX"); UserDefaults.standard.set(selectedRegion.origin.y, forKey:"regionY")
                UserDefaults.standard.set(selectedRegion.width, forKey:"regionW"); UserDefaults.standard.set(selectedRegion.height, forKey:"regionH")
            }
            let contentTask = self.recordingContentTask
            self.recordingContentTask = nil
            self.beginRecording(region: selectedRegion, screen: screen, displayID: displayID, contentTask: contentTask)
        }
    }
    func beginRecording(region r: CGRect, screen: NSScreen, displayID: CGDirectDisplayID, contentTask: Task<SCShareableContent, Error>? = nil) {
        let rec = ScreenRecorder(); recorder = rec
        isStartingRecording = true
        isRecording = false
        status = "正在启动屏幕录制…"
        let overlay = RecordingOverlayController(onStop: { [weak self] in self?.stopRecording() })
        recordingOverlay = overlay
        overlay.show(on: screen, region: r, isStarting: true)
        rec.start(region:r, displayID: displayID, contentTask: contentTask, systemAudio:systemOn, microphone:micOn, onStart: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isStartingRecording = false
                switch result {
                case .success:
                    self.isRecording = true
                    self.isQuickRecording = self.quickSaveRequested
                    self.recordingOverlay?.markRecordingStarted()
                    self.status = "录制中…再次点红色按钮结束"
                case .failure(let error):
                    self.isRecording = false
                    self.isQuickRecording = false
                    self.quickSaveRequested = false
                    self.recordingOverlay?.close()
                    self.recordingOverlay = nil
                    self.recorder = nil
                    self.status = "启动录制失败：\(error.localizedDescription)"
                    self.showMainWindow()
                }
            }
        }, onStatus: { [weak self] msg in
            Task { @MainActor in self?.status = msg }
        })
    }

    private func rememberedRegion(on screen: NSScreen) -> CGRect? {
        guard let region else { return nil }
        let fullScreen = CGRect(origin: .zero, size: screen.frame.size)
        if abs(region.minX - fullScreen.minX) < 2,
           abs(region.minY - fullScreen.minY) < 2,
           abs(region.width - fullScreen.width) < 2,
           abs(region.height - fullScreen.height) < 2 {
            return nil
        }
        return region
    }
    func stopRecording() {
        guard let rec = recorder else { return }
        let quickSave = isQuickRecording || quickSaveRequested
        isRecording = false
        recordingOverlay?.close()
        recordingOverlay = nil
        rec.stop { [weak self] url, error in Task { @MainActor in
            guard let self else { return }
            if let error { self.isQuickRecording = false; self.quickSaveRequested = false; self.status = "录制失败：\(error.localizedDescription)"; self.showMainWindow(); return }
            guard let url else { self.isQuickRecording = false; self.quickSaveRequested = false; self.status = "没有生成录制文件"; self.showMainWindow(); return }
            if quickSave {
                self.saveQuickRecording(url)
                return
            }
            self.videoDuration = 0
            self.pendingURL = url
            self.previewVideo = url
            self.mediaType = "mp4"
            self.trimStart = 0
            self.trimEnd = 1
            self.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            self.clipSegments = []
            self.showPreview = true
            self.status = "录制完成：正在打开裁剪预览…"
            self.loadVideo(url, makeTrimPreview: true)
            self.showCapturePreviewWindow()
        }}
    }

    func loadVideo(_ url:URL,makeTrimPreview:Bool) {
        stopVideoPlayer()
        let player=AVPlayer(url:url)
        videoPlayer=player
        videoIsPlaying=false
        currentVideoTime=0
        playbackObserver=player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:10),queue:.main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let current = CMTimeGetSeconds(time)
                if current.isFinite { self.currentVideoTime = current }
                guard self.videoIsPlaying else { return }
                let limit=self.videoDuration * (makeTrimPreview ? self.trimEnd : 1)
                if current >= limit { player.pause(); self.videoIsPlaying=false }
            }
        }
        Task {
            let asset = AVURLAsset(url: url)
            do { videoDuration=CMTimeGetSeconds(try await asset.load(.duration)) }
            catch { status="无法读取视频时长：\(error.localizedDescription)"; return }
            if let tracks = try? await asset.loadTracks(withMediaType: .video),
               let track = tracks.first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized
                if oriented.width > 0, oriented.height > 0 {
                    videoSize = CGSize(width: oriented.width, height: oriented.height)
                }
            }
            if makeTrimPreview { status = "录制完成：可拖动画面边框与胶片把手裁剪" }
            guard makeTrimPreview else { return }
            let duration=videoDuration
            let frames=await Task.detached(priority:.utility) { () -> [Data] in
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url))
                generator.appliesPreferredTrackTransform=true
                generator.maximumSize=CGSize(width:110,height:70)
                var results:[Data]=[]
                for index in 0..<12 {
                    let seconds=duration * (Double(index)+0.5) / 12
                    guard let (image,_)=try? await generator.image(at:CMTime(seconds:seconds,preferredTimescale:600)),
                          let data=NSBitmapImageRep(cgImage:image).representation(using:.jpeg,properties:[.compressionFactor:0.65]) else { continue }
                    results.append(data)
                }
                return results
            }.value
            timelineThumbnails=frames.compactMap(NSImage.init(data:))
        }
    }
    private func stopVideoPlayer() {
        videoPlayer?.pause(); videoIsPlaying=false
        if let playbackObserver, let videoPlayer { videoPlayer.removeTimeObserver(playbackObserver) }
        playbackObserver=nil; videoPlayer=nil; timelineThumbnails=[]
    }
    func toggleVideoPlayback() {
        guard let player=videoPlayer else { return }
        if videoIsPlaying { player.pause(); videoIsPlaying=false; return }
        let current=CMTimeGetSeconds(player.currentTime())
        let start=videoDuration*(isSavedPreview ? 0 : trimStart)
        let end=videoDuration*(isSavedPreview ? 1 : trimEnd)
        if current < start || current >= end { player.seek(to:CMTime(seconds:start,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) }
        videoIsPlaying=true; player.play()
    }
    func seekVideo(_ seconds:Double) {
        guard let player=videoPlayer else { return }
        player.pause(); videoIsPlaying=false
        let target = max(0,min(seconds,videoDuration))
        currentVideoTime = target
        player.seek(to:CMTime(seconds:target,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
    }
    func restoreTrim() { trimStart=0; trimEnd=1; cropRect=CGRect(x:0,y:0,width:1,height:1); seekVideo(0) }
    func addCurrentClipSegment() {
        guard videoDuration > 0, trimEnd - trimStart >= 0.05 else { status = "片段太短，请重新选择起止位置。"; return }
        clipSegments.append(ClipSegment(start: trimStart, end: trimEnd))
        let number = clipSegments.count
        trimStart = 0
        trimEnd = 1
        seekVideo(0)
        status = "已加入第 \(number) 段；继续选择下一段。"
    }
    func removeClipSegment(_ id: UUID) {
        clipSegments.removeAll { $0.id == id }
    }
    func exportClipSegments() {
        guard let source = pendingURL, mediaType == "mp4", !isSavedPreview else { status = "当前没有可导出的长视频。"; return }
        guard !isProcessingPreview else { return }
        guard !clipSegments.isEmpty else { status = "请先把选中的片段加入列表。"; return }
        isSaving = true
        let segments = clipSegments
        let purposeText = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPurpose = (purposeText.isEmpty ? "未命名" : purposeText)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let crop = cropRect

        if saveToEagle {
            guard let folderID = eagleFolderID, let folderPath = eagleFolderPath else {
                isSaving = false
                status = "请先选择 Eagle 保存文件夹。"
                chooseEagleFolder()
                return
            }
            Task {
                do {
                    var names = try await EagleAPI.itemNames(folderID: folderID)
                    let transferDirectory = try self.eagleTransferDirectory()
                    for (index, segment) in segments.enumerated() {
                        let suffix = String(format: "片段%02d", index + 1)
                        let itemName = self.nextEagleName(names, purposeOverride: "\(cleanPurpose)_\(suffix)")
                        let destination = self.uniqueURL(transferDirectory.appendingPathComponent("\(itemName).mp4"))
                        self.status = "正在导出并导入 Eagle：第 \(index + 1)/\(segments.count) 段…"
                        try await self.exportVideo(source: source, to: destination, start: segment.start, end: segment.end, cropRect: crop)
                        try await EagleAPI.importFile(at: destination, name: itemName, folderID: folderID, annotation: "\(purposeText.isEmpty ? "未命名" : purposeText) · \(suffix)")
                        names.append(itemName)
                    }
                    self.isSaving = false
                    self.finishSave(false, message: "已确认 \(segments.count) 段进入 Eagle / \(folderPath)。")
                } catch {
                    self.isSaving = false
                    self.status = "多片段导出中断：\(error.localizedDescription)\n原长视频仍保留；已成功导出的片段不会删除。"
                }
            }
            return
        }

        guard outputDirectory != nil else {
            isSaving = false
            status = "请先选择保存位置。"
            return
        }
        Task {
            do {
                for (index, segment) in segments.enumerated() {
                    let suffix = String(format: "片段%02d", index + 1)
                    guard let candidate = self.nextURL(ext: "mp4", purposeOverride: "\(cleanPurpose)_\(suffix)") else {
                        throw NSError(domain: "TutorialCapture", code: 30, userInfo: [NSLocalizedDescriptionKey: "无法确定项目保存位置"])
                    }
                    let destination = self.uniqueURL(candidate)
                    self.status = "正在导出片段：第 \(index + 1)/\(segments.count) 段…"
                    try await self.exportVideo(source: source, to: destination, start: segment.start, end: segment.end, cropRect: crop)
                }
                self.isSaving = false
                self.finishSave(false, message: "已导出 \(segments.count) 个视频片段到\(self.saveToDesktop ? "桌面" : "项目文件夹")。")
            } catch {
                self.isSaving = false
                self.status = "多片段导出中断：\(error.localizedDescription)\n原长视频仍保留；已成功导出的片段不会删除。"
            }
        }
    }
    private func eagleTransferDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("TutorialCapture", isDirectory: true).appendingPathComponent("EagleTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func nextURL(ext:String, purposeOverride: String? = nil) -> URL? {
        guard let folder=outputDirectory else { return nil }
        let fm=FileManager.default
        let entries=(try? fm.contentsOfDirectory(atPath:folder.path)) ?? []
        var n=1
        for name in entries { if let k=name.split(separator:"_").first, let v=Int(k) { n=max(n,v+1) } }
        let clean=(purposeOverride ?? purpose).trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-")
        return folder.appendingPathComponent(String(format:"%03d_%@.%@",n,clean.isEmpty ? "未命名" : clean,ext))
    }
    private var outputDirectory: URL? {
        if saveToDesktop { return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first }
        return saveToEagle ? nil : projectURL
    }
    private func croppedPNGData() throws -> Data {
        guard let image = previewImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "TutorialCapture", code: 41, userInfo: [NSLocalizedDescriptionKey: "无法读取截图预览"])
        }
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let requested = CGRect(
            x: cropRect.minX * CGFloat(cgImage.width),
            y: cropRect.minY * CGFloat(cgImage.height),
            width: cropRect.width * CGFloat(cgImage.width),
            height: cropRect.height * CGFloat(cgImage.height)
        ).integral
        let pixelCrop = requested.intersection(imageBounds)
        guard pixelCrop.width >= 1, pixelCrop.height >= 1,
              let cropped = cgImage.cropping(to: pixelCrop) else {
            throw NSError(domain: "TutorialCapture", code: 42, userInfo: [NSLocalizedDescriptionKey: "截图裁剪范围无效"])
        }
        let representation = NSBitmapImageRep(cgImage: cropped)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TutorialCapture", code: 43, userInfo: [NSLocalizedDescriptionKey: "无法生成裁剪后的 PNG"])
        }
        return data
    }
    private func writeCroppedPNG(to destination: URL) throws {
        try croppedPNGData().write(to: destination, options: .atomic)
    }
    func copyPending() {
        guard let source = pendingURL, !isSavedPreview, !isProcessingPreview else { return }
        isCopying = true
        let type = mediaType, start = trimStart, end = trimEnd, crop = cropRect, name = purpose
        Task {
            defer { isCopying = false }
            do {
                if type == "png" {
                    try PreviewClipboard.shared.copyImage(png: croppedPNGData())
                } else {
                    try await PreviewClipboard.shared.copyVideo(source: source, start: start, end: end, crop: crop, name: name)
                }
                status = type == "png" ? "已复制截图，可直接粘贴" : "已复制视频，可直接粘贴"
            } catch {
                status = "复制失败：\(error.localizedDescription)。预览和原素材仍保留。"
            }
        }
    }
    func savePending(continueNext:Bool = false) {
        guard let source=pendingURL else { status="没有待保存素材"; return }
        guard !isProcessingPreview else { return }
        isSaving = true
        if saveToEagle {
            guard let folderID = eagleFolderID, let folderPath = eagleFolderPath else {
                isSaving = false
                status = "请先选择 Eagle 保存文件夹。"
                chooseEagleFolder()
                return
            }
            Task {
                var exportURL: URL?
                do {
                    let existingNames = try await EagleAPI.itemNames(folderID: folderID)
                    let itemName = nextEagleName(existingNames)
                    let finalURL: URL
                    if mediaType == "png" {
                        let transferDirectory = try eagleTransferDirectory()
                        let candidate = transferDirectory.appendingPathComponent("\(itemName).png")
                        let unique = uniqueURL(candidate)
                        exportURL = unique
                        try writeCroppedPNG(to: unique)
                        finalURL = unique
                    } else {
                        // Eagle accepts a file path and may process the import after the
                        // HTTP request returns. Keep the handoff file in durable local
                        // storage so Eagle never loses it when the recording temp file
                        // is cleaned up by finishSave().
                        let support = try FileManager.default.url(
                            for: .applicationSupportDirectory,
                            in: .userDomainMask,
                            appropriateFor: nil,
                            create: true
                        )
                        let transferDirectory = support
                            .appendingPathComponent("TutorialCapture", isDirectory: true)
                            .appendingPathComponent("EagleTransfer", isDirectory: true)
                        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
                        let candidate = transferDirectory.appendingPathComponent("\(itemName).mp4")
                        let unique = uniqueURL(candidate)
                        exportURL = unique
                        try await exportVideo(source: source, to: unique)
                        finalURL = unique
                    }
                    try await EagleAPI.importFile(at: finalURL, name: itemName, folderID: folderID, annotation: purpose.trimmingCharacters(in: .whitespacesAndNewlines))
                    isSaving = false
                    let handoffNote = exportURL.map { " 交接文件保留在：\($0.path)" } ?? ""
                    finishSave(continueNext, message: "已确认素材进入 Eagle / \(folderPath)。\(continueNext ? "项目和选区已保留，可手动开始下一段。" : "")\(handoffNote)")
                } catch {
                    isSaving = false
                    let preserved = exportURL.map { "\n已导出的文件仍保留在：\($0.path)" } ?? ""
                    status = "添加到 Eagle 失败：\(error.localizedDescription)\n原始素材仍保留在临时目录。\(preserved)"
                }
            }
            return
        }
        guard let dest=nextURL(ext:mediaType) else { isSaving = false; status="请先选择本地项目文件夹"; return }
        let unique=uniqueURL(dest)
        if mediaType == "png" {
            do { try writeCroppedPNG(to:unique); isSaving = false; finishSave(continueNext) }
            catch { isSaving = false; status="保存截图失败：\(error.localizedDescription)" }
        } else {
            VideoEditor.export(source:source,to:unique,start:trimStart,end:trimEnd,cropRect:cropRect) { [weak self] error in Task { @MainActor in
                guard let self else { return }
                self.isSaving = false
                if let error { self.status="导出失败，原始录制仍保留在临时目录：\(error.localizedDescription)"; return }
                self.finishSave(continueNext)
            }}
        }
    }
    private func saveQuickRecording(_ source: URL) {
        guard !isSaving else { return }
        isSaving = true
        let quickPurpose = "快速录屏"

        if saveToEagle {
            guard let folderID = eagleFolderID, let folderPath = eagleFolderPath else {
                isSaving = false
                quickSaveFailed(source, message: "快速录屏没有导入 Eagle：请先选择 Eagle 文件夹。")
                chooseEagleFolder()
                return
            }
            Task {
                var transferURL: URL?
                do {
                    let existingNames = try await EagleAPI.itemNames(folderID: folderID)
                    let itemName = nextEagleName(existingNames, purposeOverride: quickPurpose)
                    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let transferDirectory = support.appendingPathComponent("TutorialCapture", isDirectory: true).appendingPathComponent("EagleTransfer", isDirectory: true)
                    try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
                    let destination = uniqueURL(transferDirectory.appendingPathComponent("\(itemName).mp4"))
                    transferURL = destination
                    try FileManager.default.copyItem(at: source, to: destination)
                    try await EagleAPI.importFile(at: destination, name: itemName, folderID: folderID, annotation: quickPurpose)
                    self.isSaving = false
                    self.finishSave(false, message: "快速录屏已确认进入 Eagle / \(folderPath)。交接文件保留在：\(destination.path)")
                } catch {
                    self.isSaving = false
                    let handoff = transferURL.map { "\n交接文件：\($0.path)" } ?? ""
                    self.quickSaveFailed(source, message: "快速录屏导入 Eagle 失败：\(error.localizedDescription)\(handoff)")
                }
            }
            return
        }

        guard let destination = nextURL(ext: "mp4", purposeOverride: quickPurpose) else {
            isSaving = false
            quickSaveFailed(source, message: "快速录屏未保存：请先选择保存位置。")
            return
        }
        let unique = uniqueURL(destination)
        do {
            try FileManager.default.copyItem(at: source, to: unique)
            isSaving = false
            finishSave(false, message: "快速录屏已保存：\(unique.path)")
        } catch {
            isSaving = false
            quickSaveFailed(source, message: "快速录屏保存失败：\(error.localizedDescription)\n原始录制仍保留在临时目录。")
        }
    }
    private func quickSaveFailed(_ source: URL, message: String) {
        isQuickRecording = false
        quickSaveRequested = false
        showPreview = false
        status = "\(message)\n原始录制已保留在：\(source.path)"
        NSLog("快速录屏保存失败，原始文件保留在 %@。详情：%@", source.path, message)
        // Keep the home window out of the way after a quick recording. The
        // save result remains available in the menu bar and in the saved folder.
    }
    private func exportVideo(source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            VideoEditor.export(source: source, to: destination, start: trimStart, end: trimEnd, cropRect: cropRect) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
    private func exportVideo(source: URL, to destination: URL, start: Double, end: Double, cropRect: CGRect) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            VideoEditor.export(source: source, to: destination, start: start, end: end, cropRect: cropRect) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
    private func nextEagleName(_ names: [String], purposeOverride: String? = nil) -> String {
        var next = 1
        for name in names {
            if let prefix = name.split(separator: "_").first, let number = Int(prefix) { next = max(next, number + 1) }
        }
        let clean = (purposeOverride ?? purpose).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return String(format: "%03d_%@", next, clean.isEmpty ? "未命名" : clean)
    }
    private func uniqueURL(_ url:URL)->URL {
        let parent = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stem)_\(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
    private func finishSave(_ next:Bool, message: String? = nil) {
        if let p = pendingURL { try? FileManager.default.removeItem(at: p) }
        stopVideoPlayer()
        pendingURL = nil
        previewImage = nil
        previewVideo = nil
        showPreview = false
        purpose = ""
        clipSegments = []
        isQuickRecording = false
        quickSaveRequested = false
        refreshSaved()
        status = message ?? (next ? "已保存。本期项目和选区保留；需要时再手动开始下一段。" : "素材已保存到\(saveToDesktop ? "桌面" : "项目文件夹")")
        hideMainWindow()
    }
    func discard() {
        guard !isProcessingPreview else { return }
        if let p = pendingURL { try? FileManager.default.removeItem(at: p) }
        stopVideoPlayer()
        pendingURL = nil
        previewImage = nil
        previewVideo = nil
        showPreview = false
        isSavedPreview = false
        refreshSaved()
        status = "已丢弃未确认素材"
        hideMainWindow()
    }
    func revealProject() {
        if saveToDesktop, let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first { NSWorkspace.shared.activateFileViewerSelecting([desktop]) }
        else if let p=projectURL { NSWorkspace.shared.activateFileViewerSelecting([p]) }
        else { chooseProject() }
    }
}

struct ContentView: View {
    @EnvironmentObject var m:CaptureModel
    let isPreviewWindow: Bool
    init(isPreviewWindow: Bool = false) { self.isPreviewWindow = isPreviewWindow }
    var body: some View { VStack(spacing:0) {
        if m.showPreview { preview } else {
            ScrollView(.vertical) {
                main.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            mainActions
        }
        HStack { Circle().fill(m.isRecording ? .red : .green).frame(width:8,height:8); Text(m.status).font(.callout).lineLimit(2); Spacer() }.padding(14).background(Color(nsColor:.controlBackgroundColor))
    }.background(Color(nsColor:.windowBackgroundColor)).background(WindowBehavior(isPreviewWindow: isPreviewWindow))
        .onAppear { fitWindowToCurrentMode() }
        .onChange(of: m.saveDestination) { _, _ in m.refreshSaved() }
        .onChange(of: m.showPreview) { _, _ in fitWindowToCurrentMode() }
        .onChange(of: m.mediaType) { _, _ in fitWindowToCurrentMode() }
        .sheet(isPresented: $m.showEagleFolderPicker) { EagleFolderPickerSheet(folders: m.eagleFolders, selectedID: m.eagleFolderID, onSelect: m.selectEagleFolder, onRefresh: m.chooseEagleFolder, onClose: { m.showEagleFolderPicker = false }) }
    }
    var main: some View { VStack(alignment:.leading,spacing:20) {
        VStack(alignment:.leading,spacing:8) {
            Text("素材保存位置").font(.title3.bold())
            HStack(spacing:8) {
                destinationButton("本地项目文件夹", destination: .project) { m.selectProjectDestination() }
                destinationButton("桌面", destination: .desktop) { m.selectDesktop() }
                destinationButton(m.isLoadingEagleFolders ? "正在连接 Eagle…" : "Eagle 素材库", destination: .eagle) { m.selectEagleDestination() }
                    .disabled(m.isLoadingEagleFolders)
            }
        }
        Divider()
        VStack(alignment:.leading,spacing:8) {
            Text("录制区域").font(.title3.bold())
            HStack(spacing:8) {
                captureModeButton("框选", mode: .region) { m.selectRegionMode() }
                captureModeButton("全屏", mode: .fullScreen) { m.selectFullScreenMode() }
            }
        }
        Divider()
        VStack(alignment:.leading,spacing:8) { Text("声音（默认关闭）").font(.title3.bold()); Toggle("麦克风",isOn:$m.micOn); Toggle("电脑声音",isOn:$m.systemOn) }
    }.padding(24) }

    private var mainActions: some View {
        HStack(spacing: 12) {
            Button { m.captureScreenshot() } label: { Label("截图", systemImage: "camera") }
                .buttonStyle(.borderedProminent)
            Button { m.isRecording ? m.stopRecording() : m.startRecording() } label: {
                Label(m.isStartingRecording ? "正在启动…" : (m.isRecording ? "结束录制" : "开始录制"), systemImage: m.isRecording ? "stop.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(m.isRecording ? .red : .accentColor)
            .disabled(m.isStartingRecording || m.isChoosingRegion)
            Spacer(minLength: 4)
            Button("打开素材") { m.revealProject() }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func destinationButton(_ title: String, destination: CaptureSaveDestination, action: @escaping () -> Void) -> some View {
        let selected = m.saveDestination == destination
        return Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func previewDestinationButton(_ title: String, destination: CaptureSaveDestination, action: @escaping () -> Void) -> some View {
        let selected = m.saveDestination == destination
        return Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func captureModeButton(_ title: String, mode: CaptureMode, action: @escaping () -> Void) -> some View {
        let selected = m.captureMode == mode
        return Button(action: action) {
            Text(title)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func fitWindowToCurrentMode() {
        DispatchQueue.main.async {
            let window = isPreviewWindow ? CapturePreviewWindowRegistry.shared.window : MainWindowRegistry.shared.window
            guard let window else { return }
            let isScreenshotPreview = m.showPreview && m.mediaType == "png"
            let isVideoPreview = m.showPreview && m.mediaType == "mp4"
            let targetWidth: CGFloat = isVideoPreview ? 1000 : 760
            let targetHeight: CGFloat = isScreenshotPreview ? 440 : (isVideoPreview ? 760 : 520)
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            let width = min(targetWidth, max(560, (visible?.width ?? targetWidth + 40) - 40))
            let height = min(targetHeight, max(400, (visible?.height ?? targetHeight + 80) - 80))
            let oldFrame = window.frame
            window.setContentSize(NSSize(width: width, height: height))
            var frame = window.frame
            if let visible {
                frame.origin.x = min(max(oldFrame.midX - frame.width / 2, visible.minX + 12), visible.maxX - frame.width - 12)
                frame.origin.y = min(oldFrame.maxY - frame.height, visible.maxY - frame.height - 12)
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }

    @ViewBuilder var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(m.isSavedPreview ? "素材预览" : (m.mediaType == "png" ? "截图预览" : "录屏预览与剪裁"))
                    .font(.title2.bold())
                Spacer()
                if !m.isSavedPreview {
                    previewDestinationButton("项目文件夹", destination: .project) { m.selectProjectDestination() }
                    previewDestinationButton("桌面", destination: .desktop) { m.selectDesktop() }
                    previewDestinationButton(m.isLoadingEagleFolders ? "连接中…" : "Eagle 素材库", destination: .eagle) { m.selectEagleDestination() }
                        .disabled(m.isLoadingEagleFolders)
                    Button(m.mediaType == "png" ? "重新截取" : "重录") {
                        m.discard()
                        if m.mediaType == "png" { m.captureScreenshot() } else { m.startRecording() }
                    }
                    .disabled(m.mediaType == "png" && m.isSaving)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            .disabled(m.isProcessingPreview)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        if let im = m.previewImage {
                            CropImagePreview(image: im, cropRect: $m.cropRect)
                                .frame(height: 180)
                                .background(.black.opacity(0.05))
                        } else if let player = m.videoPlayer, !m.isSavedPreview, m.mediaType == "mp4" {
                            CropVideoPreview(player: player, videoSize: m.videoSize, cropRect: $m.cropRect)
                                .frame(height: 320)
                        } else if let player = m.videoPlayer {
                            NativeVideoPlayer(player: player).frame(height: 250)
                        } else {
                            ContentUnavailableView("没有待预览素材", systemImage: "film")
                        }
                    }
                    if let _ = m.previewVideo {
                        HStack(spacing: 10) {
                            Button { m.toggleVideoPlayback() } label: {
                                Image(systemName: m.videoIsPlaying ? "pause.fill" : "play.fill").frame(width: 34, height: 42)
                            }
                            .buttonStyle(.bordered).help(m.videoIsPlaying ? "暂停预览" : "播放预览")
                            if !m.isSavedPreview && m.mediaType == "mp4" {
                                TrimFilmstrip(start: m.trimStart, end: m.trimEnd, playhead: m.currentVideoTime, duration: m.videoDuration, thumbnails: m.timelineThumbnails,
                                    onChange: { start, end in m.trimStart = start; m.trimEnd = end }, onSeek: { m.seekVideo($0) })
                                    .frame(height: 66)
                            }
                        }
                    }
                    if !m.isSavedPreview && m.mediaType == "mp4" { trimControls }
                    if !m.isSavedPreview {
                        TextField("备注名称（会写入文件名）", text: $m.purpose)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(m.isProcessingPreview)

            Divider()
            previewActions
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var previewActions: some View {
        HStack(spacing: 8) {
            if m.isSavedPreview {
                if let url = m.currentSavedURL { Button("在访达中显示") { m.revealFile(url) } }
                Button("返回素材列表") { m.leaveSavedPreview() }
            } else {
                Button(m.isSaving ? "正在保存…" : "保存") { m.savePending() }
                    .buttonStyle(.borderedProminent).disabled(m.isProcessingPreview)
                Button(m.isCopying ? "正在复制…" : "复制") { m.copyPending() }
                    .buttonStyle(.bordered).disabled(m.isProcessingPreview)
                    .help("复制当前剪裁结果，不保存到素材文件夹")
                if m.mediaType == "mp4", !m.clipSegments.isEmpty {
                    Button(m.isSaving ? "正在导出…" : "导出全部 \(m.clipSegments.count) 段") { m.exportClipSegments() }
                        .buttonStyle(.borderedProminent).disabled(m.isProcessingPreview)
                }
                Spacer(minLength: 4)
                Button("丢弃") { m.discard() }.tint(.red).disabled(m.isProcessingPreview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimControls: some View {
        let duration=max(m.videoDuration,0.1)
        return VStack(alignment:.leading,spacing:7) {
            Text("画面保留范围")
            HStack(spacing:10) {
                Button("加入片段") { m.addCurrentClipSegment() }
                    .disabled(m.isSaving || duration <= 0)
                Text("已选 \(m.clipSegments.count) 段")
                    .font(.callout.weight(.medium).monospacedDigit())
                Spacer()
            }
            Text("调整好一段的起止位置后加入列表；导出前可逐段点击“移除”纠正选错的片段。")
                .font(.caption).foregroundStyle(.secondary)
            if !m.clipSegments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing:6) {
                        ForEach(Array(m.clipSegments.enumerated()), id: \.element.id) { item in
                            HStack(spacing:5) {
                                Text("\(item.offset + 1)  \(formatClipTime(duration * item.element.start))–\(formatClipTime(duration * item.element.end))")
                                    .font(.caption.monospacedDigit())
                                Button("移除") { m.removeClipSegment(item.element.id) }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                    .help("从待导出列表移除此片段")
                            }
                            .padding(.horizontal,8).padding(.vertical,5)
                            .background(Color(nsColor:.controlBackgroundColor), in:Capsule())
                        }
                    }
                }
                .frame(height:30)
            }
        }
    }

    private func formatClipTime(_ seconds:Double)->String {
        let safe=max(0,seconds)
        let minutes=Int(safe)/60
        let remainder=safe-Double(minutes*60)
        return String(format:"%02d:%04.1f",minutes,remainder)
    }
}

private struct TrimFilmstrip: View {
    let start:Double
    let end:Double
    let playhead:Double
    let duration:Double
    let thumbnails:[NSImage]
    let onChange:(Double,Double)->Void
    let onSeek:(Double)->Void
    @State private var dragging:DragTarget?

    private enum DragTarget: Equatable { case start,end,playhead }

    var body: some View {
        GeometryReader { geometry in
            let width=max(geometry.size.width,1)
            let left=width*min(max(start,0),1)
            let right=width*min(max(end,0),1)
            let playheadX=width*min(max(playhead/max(duration,0.001),0),1)
            let activeX: CGFloat = dragging == .start ? left : (dragging == .end ? right : playheadX)
            ZStack(alignment:.topLeading) {
                HStack(spacing:0) {
                    if thumbnails.isEmpty { Rectangle().fill(Color.black.opacity(0.75)) }
                    else {
                        ForEach(Array(thumbnails.enumerated()),id:\.offset) { item in
                            Image(nsImage:item.element).resizable().scaledToFill().frame(maxWidth:.infinity).clipped()
                        }
                    }
                }
                .frame(height:42).clipShape(RoundedRectangle(cornerRadius:5))
                HStack(spacing:0) {
                    Rectangle().fill(Color.black.opacity(0.58)).frame(width:max(0,left))
                    Spacer(minLength:0)
                    Rectangle().fill(Color.black.opacity(0.58)).frame(width:max(0,width-right))
                }
                .frame(height:42).clipShape(RoundedRectangle(cornerRadius:5))
                RoundedRectangle(cornerRadius:5).stroke(Color.yellow,lineWidth:3)
                    .frame(width:max(4,right-left),height:42).offset(x:left)
                handle.offset(x:max(0,min(width-12,left-6)),y:13)
                handle.offset(x:max(0,min(width-12,right-6)),y:13)
                Capsule().fill(Color.white).frame(width:2,height:46)
                    .shadow(color:.black.opacity(0.8),radius:2)
                    .offset(x:max(0,min(width-2,playheadX-1)),y:-2)
                Circle().fill(Color.white).frame(width:10,height:10)
                    .overlay(Circle().stroke(Color.black.opacity(0.65),lineWidth:1))
                    .offset(x:max(0,min(width-10,playheadX-5)),y:-3)
                if let dragging {
                    Text(formatTime(dragging == .start ? duration * start : (dragging == .end ? duration * end : playhead)))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal,7).padding(.vertical,3)
                        .background(Color(nsColor:.windowBackgroundColor),in:Capsule())
                        .overlay(Capsule().stroke(Color.yellow,lineWidth:1))
                        .position(x:max(34,min(width-34,activeX)),y:7)
                }
            }
            .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .coordinateSpace(name:"filmstrip")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("filmstrip"))
                .onChanged { value in
                    guard width > 0 else { return }
                    if dragging == nil {
                        let startDistance = abs(value.location.x-left)
                        let endDistance = abs(value.location.x-right)
                        if min(startDistance,endDistance) <= 12 {
                            dragging = startDistance <= endDistance ? .start : .end
                        } else {
                            dragging = .playhead
                        }
                    }
                    let position=min(max(value.location.x/width,0),1)
                    let gap=min(0.05/max(duration,0.1),0.1)
                    if dragging == .start {
                        let newStart=min(position,max(0,end-gap))
                        onChange(newStart,end); onSeek(duration*newStart)
                    } else if dragging == .end {
                        let newEnd=max(position,min(1,start+gap))
                        onChange(start,newEnd); onSeek(duration*newEnd)
                    } else {
                        onSeek(duration*position)
                    }
                }
                .onEnded { _ in dragging=nil })
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("视频裁切胶片带")
            .accessibilityValue("播放位置 \(formatTime(playhead))；保留 \(formatTime(duration*start)) 至 \(formatTime(duration*end))")
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius:2).fill(Color.yellow).frame(width:12,height:30)
            .overlay(Image(systemName:"line.3.horizontal").font(.system(size:8,weight:.bold)).foregroundStyle(.black.opacity(0.8)))
    }

    private func formatTime(_ seconds:Double)->String {
        let safe=max(0,seconds); let minutes=Int(safe)/60; let remainder=safe-Double(minutes*60)
        return String(format:"%02d:%04.1f",minutes,remainder)
    }
}

private struct CropImagePreview: View {
    let image: NSImage
    @Binding var cropRect: CGRect

    var body: some View {
        GeometryReader { geometry in
            let imageSize = pixelSize
            let imageRect = fittedImageRect(container: geometry.size, image: imageSize)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.08)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                CropSelectionOverlay(cropRect: $cropRect, videoRect: imageRect)
            }
            .clipped()
        }
    }

    private var pixelSize: CGSize {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image.size }
        return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    }

    private func fittedImageRect(container: CGSize, image: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, image.width > 0, image.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}

private struct CropVideoPreview: View {
    let player: AVPlayer
    let videoSize: CGSize
    @Binding var cropRect: CGRect

    var body: some View {
        GeometryReader { geometry in
            let videoRect = fittedVideoRect(container: geometry.size, video: videoSize)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.08)
                NativeVideoPlayer(player: player)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
                CropSelectionOverlay(cropRect: $cropRect, videoRect: videoRect)
            }
            .clipped()
        }
    }

    private func fittedVideoRect(container: CGSize, video: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, video.width > 0, video.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / video.width, container.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}

private struct EagleFolderPickerSheet: View {
    let folders: [EagleFolderOption]
    let selectedID: String?
    let onSelect: (EagleFolderOption) -> Void
    let onRefresh: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择 Eagle 文件夹").font(.title2.bold())
                Spacer()
                Button("刷新") { onRefresh() }
                Button("关闭") { onClose() }
            }
            Text("选择后，之后确认保存的截图和视频会导入此文件夹。")
                .font(.callout).foregroundStyle(.secondary)
            if folders.isEmpty {
                ContentUnavailableView("没有可用文件夹", systemImage: "folder.badge.questionmark", description: Text("请确认 Eagle 已打开并创建了文件夹，然后点“刷新”。"))
            } else {
                List(folders) { folder in
                    Button { onSelect(folder) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedID == folder.id ? "folder.fill.badge.checkmark" : "folder")
                                .foregroundStyle(selectedID == folder.id ? Color.accentColor : Color.secondary)
                            Text(folder.path).lineLimit(1)
                            Spacer(minLength: 8)
                            if selectedID == folder.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .padding(.leading, CGFloat(folder.depth) * 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(width: 500, height: 520)
    }
}

private struct CropSelectionOverlay: View {
    @Binding var cropRect: CGRect
    let videoRect: CGRect
    @State private var dragOrigin: CGRect?
    @State private var activeHandle: CropHandle?
    @State private var isMoving = false

    private enum CropHandle: CaseIterable, Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    var body: some View {
        let box = CGRect(
            x: videoRect.minX + cropRect.minX * videoRect.width,
            y: videoRect.minY + cropRect.minY * videoRect.height,
            width: cropRect.width * videoRect.width,
            height: cropRect.height * videoRect.height
        )
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(videoRect)
                path.addRect(box)
            }
            .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .gesture(moveGesture)
                .help("拖动裁剪框移动保留画面")

            ForEach(CropHandle.allCases, id: \.self) { handle in
                handleView(handle)
                    .position(point(for: handle, in: box))
                    .gesture(resizeGesture(handle))
                    .help("拖动调整裁剪范围")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频画面裁剪框")
    }

    private func handleView(_ handle: CropHandle) -> some View {
        let corner = [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
        let horizontal = handle == .top || handle == .bottom
        return Group {
            if corner {
                Circle().fill(Color.white).overlay(Circle().stroke(Color.yellow, lineWidth: 2))
                    .frame(width: 14, height: 14)
            } else {
                Capsule().fill(Color.white).overlay(Capsule().stroke(Color.yellow, lineWidth: 2))
                    .frame(width: horizontal ? 26 : 8, height: horizontal ? 8 : 26)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private func point(for handle: CropHandle, in box: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: box.minX, y: box.minY)
        case .top: CGPoint(x: box.midX, y: box.minY)
        case .topRight: CGPoint(x: box.maxX, y: box.minY)
        case .right: CGPoint(x: box.maxX, y: box.midY)
        case .bottomRight: CGPoint(x: box.maxX, y: box.maxY)
        case .bottom: CGPoint(x: box.midX, y: box.maxY)
        case .bottomLeft: CGPoint(x: box.minX, y: box.maxY)
        case .left: CGPoint(x: box.minX, y: box.midY)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isMoving {
                    isMoving = true
                    dragOrigin = cropRect
                }
                guard let origin = dragOrigin else { return }
                let dx = value.translation.width / max(videoRect.width, 1)
                let dy = value.translation.height / max(videoRect.height, 1)
                let x = min(max(0, origin.minX + dx), 1 - origin.width)
                let y = min(max(0, origin.minY + dy), 1 - origin.height)
                cropRect = CGRect(x: x, y: y, width: origin.width, height: origin.height)
            }
            .onEnded { _ in isMoving = false; dragOrigin = nil }
    }

    private func resizeGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeHandle != handle {
                    activeHandle = handle
                    dragOrigin = cropRect
                }
                guard let origin = dragOrigin else { return }
                cropRect = resized(
                    origin,
                    handle: handle,
                    dx: value.translation.width / max(videoRect.width, 1),
                    dy: value.translation.height / max(videoRect.height, 1)
                )
            }
            .onEnded { _ in activeHandle = nil; dragOrigin = nil }
    }

    private func resized(_ rect: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minimum: CGFloat = 0.06
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: left = min(max(rect.minX + dx, 0), rect.maxX - minimum)
        case .topRight, .right, .bottomRight: right = max(min(rect.maxX + dx, 1), rect.minX + minimum)
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight: top = min(max(rect.minY + dy, 0), rect.maxY - minimum)
        case .bottomLeft, .bottom, .bottomRight: bottom = max(min(rect.maxY + dy, 1), rect.minY + minimum)
        default: break
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// AVKit's SwiftUI VideoPlayer crashes during SwiftUI view updates on this
/// macOS/SDK combination. Host the native AVPlayerView directly instead.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player?.pause(); view.player = player }
    }
}

struct WindowBehavior:NSViewRepresentable {
    var isPreviewWindow = false
    func makeNSView(context:Context)->NSView { let v=NSView(); configure(v); return v }
    func updateNSView(_ view:NSView,context:Context) { configure(view) }
    private func configure(_ view:NSView) {
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            if self.isPreviewWindow {
                w.identifier = NSUserInterfaceItemIdentifier("TutorialCapture.PreviewWindow")
                CapturePreviewWindowRegistry.shared.window = w
                w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
            } else {
                w.identifier = NSUserInterfaceItemIdentifier("TutorialCapture.MainWindow")
                MainWindowRegistry.shared.window = w
                w.collectionBehavior.remove(.canJoinAllSpaces)
            }
            w.isMovableByWindowBackground = false
            w.level = .normal
        }
    }
}

private struct WindowDragHandle:NSViewRepresentable {
    func makeNSView(context:Context)->NSView { WindowDragView() }
    func updateNSView(_ view:NSView,context:Context) {}
}

private final class WindowDragView:NSView {
    override var mouseDownCanMoveWindow:Bool { true }
}

@MainActor private final class RecordingOverlayController: NSObject {
    private var panel: NSPanel?
    private var buttonPanel: NSPanel?
    private var stopAction: (() -> Void)?
    private weak var durationLabel: NSTextField?
    private weak var stopButton: NSButton?
    private var durationTimer: Timer?
    private var recordingStartedAt: TimeInterval = 0
    private var orderObservers: [(NotificationCenter, NSObjectProtocol)] = []

    init(onStop: @escaping () -> Void) {
        stopAction = onStop
        super.init()
    }

    func show(on screen: NSScreen, region: CGRect, isStarting: Bool = false) {
        let panel = RecordingOverlayPanel(contentRect: screen.frame)
        panel.title = "录制范围 - 刘老大"
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let view = RecordingOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), region: region)
        panel.contentView = view
        self.panel = panel
        panel.orderFrontRegardless()

        let button = RecordingStopButton(title: "结束录制", target: self, action: #selector(stopRecording))
        button.isEnabled = !isStarting
        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemRed.cgColor
        button.layer?.cornerRadius = 10
        button.contentTintColor = .white
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        let buttonSize = CGSize(width: 104, height: 34)
        let labelSize = CGSize(width: 110, height: 34)
        let spacing: CGFloat = 8
        let controlSize = CGSize(width: labelSize.width + spacing + buttonSize.width, height: buttonSize.height)
        let x = min(max(0, region.maxX - controlSize.width), screen.frame.width - controlSize.width)
        let y = region.minY >= controlSize.height + 8 ? region.minY - controlSize.height - 8 : region.maxY + 8
        let controlsFrame = CGRect(x: x, y: min(max(0, y), screen.frame.height - controlSize.height), width: controlSize.width, height: controlSize.height)

        let buttonPanel = RecordingOverlayPanel(
            contentRect: CGRect(
                x: screen.frame.minX + controlsFrame.minX,
                y: screen.frame.minY + screen.frame.height - controlsFrame.maxY,
                width: controlSize.width,
                height: controlSize.height
            )
        )
        buttonPanel.title = "录制控制 - 刘老大"
        buttonPanel.level = .screenSaver
        buttonPanel.hidesOnDeactivate = false
        buttonPanel.isFloatingPanel = true
        buttonPanel.backgroundColor = .clear
        buttonPanel.isOpaque = false
        buttonPanel.hasShadow = false
        buttonPanel.ignoresMouseEvents = false
        let controls = NSView(frame: CGRect(origin: .zero, size: controlSize))
        let label = NSTextField(labelWithString: isStarting ? "准备录制…" : "录制 00:00:00")
        label.alignment = .center
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        label.wantsLayer = true
        label.layer?.cornerRadius = 10
        label.frame = CGRect(x: 0, y: 0, width: labelSize.width, height: labelSize.height)
        button.frame = CGRect(x: labelSize.width + spacing, y: 0, width: buttonSize.width, height: buttonSize.height)
        controls.addSubview(label)
        controls.addSubview(button)
        buttonPanel.contentView = controls
        self.buttonPanel = buttonPanel
        durationLabel = label
        stopButton = button
        observeWindowOrdering()
        buttonPanel.orderFrontRegardless()
        if !isStarting { markRecordingStarted() }
    }

    func markRecordingStarted() {
        durationTimer?.invalidate()
        stopButton?.isEnabled = true
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        updateDurationLabel()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDurationLabel() }
        }
        durationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        restoreWindowOrdering()
    }

    private func observeWindowOrdering() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restoreAfterWorkspaceTransition() }
            }
            orderObservers.append((workspaceCenter, token))
        }
        let appCenter = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            let token = appCenter.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.restoreAfterWorkspaceTransition() }
            }
            orderObservers.append((appCenter, token))
        }
    }

    private func restoreAfterWorkspaceTransition() {
        restoreWindowOrdering()
        // Full-screen and Space transitions finish after the activation event.
        for delay in [0.25, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restoreWindowOrdering()
            }
        }
    }

    private func restoreWindowOrdering() {
        panel?.orderFrontRegardless()
        buttonPanel?.orderFrontRegardless()
    }

    private func updateDurationLabel() {
        let elapsed = max(0, Int(ProcessInfo.processInfo.systemUptime - recordingStartedAt))
        let hours = elapsed / 3600
        let minutes = (elapsed / 60) % 60
        let seconds = elapsed % 60
        durationLabel?.stringValue = String(format: "录制 %02d:%02d:%02d", hours, minutes, seconds)
    }

    func close() {
        durationTimer?.invalidate()
        durationTimer = nil
        durationLabel = nil
        stopButton = nil
        for (center, token) in orderObservers { center.removeObserver(token) }
        orderObservers.removeAll()
        buttonPanel?.orderOut(nil)
        buttonPanel?.close()
        buttonPanel = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        stopAction = nil
    }

    @objc private func stopRecording() {
        stopAction?()
    }
}

private final class RecordingOverlayPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        canHide = false
        isFloatingPanel = true
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingStopButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private enum CaptureSelectionStyle {
    static let blue = NSColor(srgbRed: 0.18, green: 0.40, blue: 0.95, alpha: 1)
    static func draw(in bounds: CGRect, selection: CGRect?) {
        // Clear the previous mask, then dim only outside the selection. A tinted
        // panel background would darken the selected area even through this hole.
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let clipped = selection?.intersection(bounds)
        let dim = NSBezierPath(rect: bounds)
        if let clipped, !clipped.isEmpty { dim.appendRect(clipped) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.32).setFill()
        dim.fill()
        if let clipped, !clipped.isEmpty {
            blue.setStroke()
            let outline = NSBezierPath(rect: clipped.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}

@MainActor private final class RecordingOverlayView: NSView {
    let region: CGRect

    override var isFlipped: Bool { true }

    init(frame: CGRect, region: CGRect) {
        self.region = region
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        CaptureSelectionStyle.draw(in: bounds, selection: region)
    }

}

struct RegionPicker {
    @MainActor static func show(on screen:NSScreen, completion:@escaping(CGRect?)->Void) {
        let panel = CaptureRegionSelectionPanel(screen: screen)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let presenter = RecordingRegionPanelPresenter()
        presenter.panel = panel
        presenter.completion = completion
        RecordingRegionPanelPresenter.active = presenter
        panel.contentView = ScreenshotRegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size)) { [weak presenter] selection in
            presenter?.finish(selection)
        }

        // Let the menu/button that launched screenshot finish its mouse-up before
        // enabling selection, so the first selection starts with the next drag.
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard presenter.completion != nil else { return }
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKey()
            if let contentView = panel.contentView { panel.makeFirstResponder(contentView) }
        }
    }
}

private final class CaptureRegionSelectionPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // A regular NSPanel hides when its app is in the background. A menu-bar
        // capture must remain visible and accept the first drag in the current Space.
        hidesOnDeactivate = false
        canHide = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovable = false
        title = "框选区域 - 刘老大"
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class ScreenshotRegionSelectionView: NSView {
    private let onSelect: (CGRect?) -> Void
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var header: NSView!

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, onSelect: @escaping (CGRect?) -> Void) {
        self.onSelect = onSelect
        super.init(frame: frame)
        wantsLayer = true

        let label = NSTextField(labelWithString: "拖动框选截图区域 · 松开后预览 · Esc 取消")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.frame = CGRect(x: 12, y: 10, width: label.intrinsicContentSize.width, height: 22)

        header = NSView(frame: CGRect(x: 0, y: 22, width: label.frame.width + 82, height: 42))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        header.layer?.cornerRadius = 12
        label.frame.origin.y = 10
        header.addSubview(label)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelSelection))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = CGRect(x: label.frame.maxX + 10, y: 6, width: 54, height: 30)
        header.addSubview(cancelButton)
        header.frame.origin.x = (frame.width - header.frame.width) / 2
        addSubview(header)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let selection = dragStart.flatMap { start in dragEnd.map { rect(from: start, to: $0) } }
        CaptureSelectionStyle.draw(in: bounds, selection: selection)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragEnd = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragEnd = nil
        needsDisplay = true
        let selection = rect(from: start, to: end)
        if selection.width > 30, selection.height > 30 { onSelect(selection) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onSelect(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onSelect(nil) }

    @objc private func cancelSelection() { onSelect(nil) }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
@MainActor private final class RecordingRegionPanelPresenter {
    static var active: RecordingRegionPanelPresenter?
    var panel: NSPanel?
    var completion: ((CGRect?) -> Void)?

    func finish(_ region: CGRect?) {
        let callback = completion
        completion = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        if Self.active === self { Self.active = nil }
        callback?(region)
    }
}

@MainActor private enum RecordingRegionPicker {
    static func show(on screen: NSScreen, previousRegion: CGRect?, completion: @escaping (CGRect?) -> Void) {
        let panel = CaptureRegionSelectionPanel(screen: screen)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let presenter = RecordingRegionPanelPresenter()
        presenter.panel = panel
        presenter.completion = completion
        RecordingRegionPanelPresenter.active = presenter
        panel.contentView = RecordingRegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), previousRegion: previousRegion) { [weak presenter] selection in
            presenter?.finish(selection)
        }
        // Show feedback immediately, while briefly ignoring the click that opened the
        // menu item so its mouse-up cannot select the previous region.
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard presenter.completion != nil else { return }
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKey()
            if let contentView = panel.contentView {
                panel.makeFirstResponder(contentView)
            }
        }
    }
}

private final class RecordingRegionSelectionView: NSView {
    private let previousRegion: CGRect?
    private let onSelect: (CGRect?) -> Void
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var isDrawingNewRegion = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect, previousRegion: CGRect?, onSelect: @escaping (CGRect?) -> Void) {
        self.previousRegion = previousRegion
        self.onSelect = onSelect
        super.init(frame: frame)
        wantsLayer = true

        let message = previousRegion == nil
            ? "拖动框选区域，松开后立即开始录制 · Esc 取消"
            : "点击蓝色框立即录制 · 拖动框选新区域并立即录制 · Esc 取消"
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = CGRect(x: 14, y: 10, width: label.intrinsicContentSize.width, height: 24)

        let header = NSView(frame: CGRect(x: (frame.width - label.frame.width - 28) / 2, y: 22, width: label.frame.width + 28, height: 44))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        header.layer?.cornerRadius = 12
        header.addSubview(label)
        addSubview(header)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dragged = dragStart.flatMap { start in dragEnd.map { rect(from: start, to: $0) } }
        let selection = isDrawingNewRegion ? dragged : (previousRegion ?? dragged)
        CaptureSelectionStyle.draw(in: bounds, selection: selection)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragEnd = point
        isDrawingNewRegion = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragEnd = convert(event.locationInWindow, from: nil)
        if let dragStart, hypot(dragEnd!.x - dragStart.x, dragEnd!.y - dragStart.y) >= 8 {
            isDrawingNewRegion = true
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Ignore an orphaned mouse-up from the button/menu that opened this panel.
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragEnd = nil
        isDrawingNewRegion = false
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance < 8 {
            if let previousRegion, previousRegion.contains(start) { onSelect(previousRegion) }
            needsDisplay = true
            return
        }
        let selection = rect(from: start, to: end)
        if selection.width > 30, selection.height > 30 { onSelect(selection) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onSelect(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onSelect(nil) }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
struct PickerView: View {
    let done:(CGRect?)->Void; @State private var start:CGPoint?; @State private var current:CGPoint?
    var body:some View { GeometryReader { _ in ZStack { Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:1).onChanged { if start == nil { start=$0.startLocation }; current=$0.location }.onEnded { v in let a=v.startLocation,b=v.location; let r=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)); if r.width>30 && r.height>30 { done(r) } }); if let a=start,let b=current { let r=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)); Rectangle().stroke(.yellow,lineWidth:2).frame(width:r.width,height:r.height).position(x:r.midX,y:r.midY) }; VStack { Text("拖动框选录制区域 · 松开确认 · 按 Esc 取消").padding(10).background(.black.opacity(0.7)).foregroundStyle(.white); Spacer(); Button("取消") { done(nil) }.padding() }.padding() } }.onExitCommand { done(nil) } }
}
