import Foundation
import AVFoundation
import CoreImage
import SwiftSignalKit
import TelegramCore
import TelegramVoip
import TelegramCallsUI
import AccountContext
import GGCallAudio
import GGCore

/// Follows the current 1:1 call: applies a change of the silent-mute setting to a call in progress
/// and records the call when one of the recording switches is on. The call's state is observed only
/// while a recording switch is on (switching both off mid-call ends the recording and keeps the
/// file); with both off a call costs nothing here.
///
/// Recordings are saved on this device only, in the account's own directory
/// (`<account>/ghostgram/call-recordings`, outside `/calls` that upstream prunes). Nothing is
/// uploaded: «Отправить в Избранное» and «Поделиться» are buttons in the list of recordings.
final class GGCallRecordingCoordinator {
    static let shared = GGCallRecordingCoordinator()

    private var isStarted = false
    private let callDisposable = MetaDisposable()
    private let stateDisposable = MetaDisposable()
    private let reapplyMuteDisposable = MetaDisposable()
    private var silentMuteDisposable: Disposable?

    private weak var currentCall: PresentationCallImpl?
    private var lastSilentMute: Bool?
    private var session: GGCallRecordingSession?

    private let recordingCallsPromise = ValuePromise<Set<CallSessionInternalId>>(Set(), ignoreRepeated: true)
    private var recordingCalls = Set<CallSessionInternalId>() {
        didSet {
            self.recordingCallsPromise.set(self.recordingCalls)
        }
    }

    private init() {
    }

    /// Whether the call is being recorded right now (the overlay's «● REC»).
    func isRecording(callId: CallSessionInternalId) -> Signal<Bool, NoError> {
        return self.recordingCallsPromise.get()
        |> map { $0.contains(callId) }
        |> distinctUntilChanged
    }

    /// Main thread; idempotent. The call manager is shared by all accounts.
    func start(sharedContext: SharedAccountContext) {
        if self.isStarted {
            return
        }
        guard let callManager = sharedContext.callManager else {
            return
        }
        self.isStarted = true
        self.callDisposable.set((callManager.currentCallSignal
        |> deliverOnMainQueue).start(next: { [weak self] call in
            self?.updateCurrentCall(call as? PresentationCallImpl)
        }))
        // «Тихое выключение микрофона» switched mid-call: re-apply the current mute through the policy.
        self.silentMuteDisposable = (GGCallsMediaSettings.silentMute.signal
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let strongSelf = self else {
                return
            }
            let previous = strongSelf.lastSilentMute
            strongSelf.lastSilentMute = value
            guard previous != nil, previous != value, let call = strongSelf.currentCall else {
                return
            }
            // The mute button's current state (ValuePromise: delivered at once), applied again through
            // the policy so the device and the call agree with the new setting.
            strongSelf.reapplyMuteDisposable.set((call.isMuted
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak call] isMuted in
                call?.setIsMuted(isMuted)
            }))
        })
    }

    private func updateCurrentCall(_ call: PresentationCallImpl?) {
        if self.currentCall === call && call != nil {
            return
        }
        self.finishSession()
        self.currentCall = call
        self.reapplyMuteDisposable.set(nil)
        guard let call = call else {
            self.stateDisposable.set(nil)
            return
        }
        let wantsRecording = GGCallsMediaSettings.recordCalls.signal
        |> map { value -> Bool in
            return GGCallRecordingMode.resolved(value).isOn
        }
        |> distinctUntilChanged
        self.stateDisposable.set((wantsRecording
        |> mapToSignal { wants -> Signal<PresentationCallState?, NoError> in
            return wants ? (call.state |> map(Optional.init)) : .single(nil)
        }
        |> deliverOnMainQueue).start(next: { [weak self, weak call] state in
            guard let strongSelf = self, let call = call else {
                return
            }
            if let state = state {
                strongSelf.callStateUpdated(call: call, state: state)
            } else {
                // «Записывать звонки» went to «Нет»: whatever was recorded so far is saved.
                strongSelf.finishSession()
            }
        }))
    }

    private func callStateUpdated(call: PresentationCallImpl, state: PresentationCallState) {
        switch state.state {
        case .active, .reconnecting:
            let mode = GGCallsMediaSettings.recordingMode
            let hasVideo = GGCallRecordingCoordinator.hasVideo(state)
            if let session = self.session {
                session.videoStateUpdated(hasVideo: hasVideo)
                return
            }
            guard mode.isOn, let effects = call.sharedAudioContext?.audioDevice?.ggAudioEffects else {
                return
            }
            // Every call starts as audio; with «Аудио и видео» a call that has video records video.
            let initialKind: GGCallRecorder.Kind = (hasVideo && mode.recordsVideo) ? .video : .audio
            let session = GGCallRecordingSession(call: call, effects: effects, initialKind: initialKind, recordVideo: mode.recordsVideo, includeMicrophone: GGCallsMediaSettings.recordOwnVoice.value)
            self.session = session
            self.recordingCalls.insert(call.internalId)
            session.start()
        case .terminating, .terminated:
            self.finishSession()
        default:
            break
        }
    }

    private func finishSession() {
        guard let session = self.session else {
            return
        }
        self.session = nil
        self.recordingCalls.remove(session.callId)
        session.finish()
    }

    private static func hasVideo(_ state: PresentationCallState) -> Bool {
        switch state.videoState {
        case .active, .paused:
            return true
        default:
            break
        }
        switch state.remoteVideoState {
        case .active, .paused:
            return true
        case .inactive:
            return false
        }
    }
}

/// One recorded call: one or more files (an audio call that turns into a video call continues in a
/// new video file). All writing happens on `queue`.
private final class GGCallRecordingSession {
    let callId: CallSessionInternalId
    private let context: AccountContext
    private let effects: GGCallAudioEffects
    private let recordVideo: Bool
    private let includeMicrophone: Bool
    private let peerKey: GGPeerKey?
    private let peerTitle: String
    private weak var call: PresentationCallImpl?

    private let queue = Queue(name: "org.ghostgram.callRecording")
    private var kind: GGCallRecorder.Kind

    // Session queue only.
    private var recorder: GGCallRecorder?
    private var recorderStartDate: Double = 0.0
    private var drainTimer: SwiftSignalKit.Timer?
    private var compositor: GGCallVideoCompositor?
    private var remoteImage: CIImage?
    private var localImage: CIImage?
    private var isFinished = false

    private let remoteVideoDisposable = MetaDisposable()
    private let localVideoDisposable = MetaDisposable()

    init(call: PresentationCallImpl, effects: GGCallAudioEffects, initialKind: GGCallRecorder.Kind, recordVideo: Bool, includeMicrophone: Bool) {
        self.callId = call.internalId
        self.context = call.context
        self.effects = effects
        self.kind = initialKind
        self.recordVideo = recordVideo
        self.includeMicrophone = includeMicrophone
        self.peerKey = call.peerId.ggKey
        self.peerTitle = call.peer?.compactDisplayTitle ?? ""
        self.call = call
    }

    deinit {
        self.remoteVideoDisposable.dispose()
        self.localVideoDisposable.dispose()
    }

    /// Main thread.
    func start() {
        self.effects.startRecording(includingMicrophone: self.includeMicrophone)
        let kind = self.kind
        self.queue.async { [self] in
            self.startSegment(kind: kind)
            let timer = SwiftSignalKit.Timer(timeout: 0.5, repeat: true, completion: { [weak self] in
                self?.drain()
            }, queue: self.queue)
            self.drainTimer = timer
            timer.start()
        }
        if kind == .video {
            self.subscribeVideo()
        }
    }

    /// Main thread: the call's video went on (audio → video upgrade) or changed.
    func videoStateUpdated(hasVideo: Bool) {
        if hasVideo && self.recordVideo && self.kind == .audio {
            self.kind = .video
            self.queue.async {
                self.drain()
                self.finishSegment()
                self.startSegment(kind: .video)
            }
        }
        if self.kind == .video {
            // The own camera's signal exists only once video was requested.
            self.subscribeVideo()
        }
    }

    /// Main thread.
    func finish() {
        self.remoteVideoDisposable.set(nil)
        self.localVideoDisposable.set(nil)
        self.queue.async {
            self.drainTimer?.invalidate()
            self.drainTimer = nil
            self.drain()
            self.isFinished = true
            self.finishSegment()
            self.effects.stopRecording()
        }
    }

    private func subscribeVideo() {
        guard let call = self.call else {
            return
        }
        if let remote = call.video(isIncoming: true) {
            self.remoteVideoDisposable.set(remote.start(next: { [weak self] frame in
                self?.queue.async {
                    self?.remoteFrame(frame)
                }
            }))
        }
        if let local = call.video(isIncoming: false) {
            self.localVideoDisposable.set(local.start(next: { [weak self] frame in
                self?.queue.async {
                    self?.localFrame(frame)
                }
            }))
        }
    }

    // MARK: Session queue

    private func startSegment(kind: GGCallRecorder.Kind) {
        let directory = GGCallRecordingStorage.directory(basePath: self.context.account.basePath)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fileName = GGCallRecordingStorage.fileName(date: Date(), kind: kind)
        let url = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
        self.recorder = GGCallRecorder(url: url, kind: kind, queue: self.queue)
        self.recorderStartDate = Date().timeIntervalSince1970
        if kind == .video && self.compositor == nil {
            self.compositor = GGCallVideoCompositor()
        }
        if self.recorder == nil {
            GGLog.warning("calls", "recording: the writer did not start")
        }
    }

    private func drain() {
        guard let recorder = self.recorder else {
            // Keep the rings empty while no file is open.
            let _ = self.effects.drainRecording()
            return
        }
        if let chunk = self.effects.drainRecording() {
            recorder.appendAudio(chunk)
        }
        // Without new frames the video keeps one frame per second, so the file has no holes.
        if recorder.kind == .video {
            let now = CACurrentMediaTime()
            if recorder.secondsSinceLastVideoFrame(at: now) > 1.0 {
                self.composeFrame(at: now)
            }
        }
    }

    private func remoteFrame(_ frame: OngoingGroupCallContext.VideoFrameData) {
        guard let recorder = self.recorder, let compositor = self.compositor else {
            return
        }
        let now = CACurrentMediaTime()
        guard recorder.wantsVideoFrame(at: now) else {
            return
        }
        self.remoteImage = compositor.image(frame)
        self.composeFrame(at: now)
    }

    private func localFrame(_ frame: OngoingGroupCallContext.VideoFrameData) {
        guard let recorder = self.recorder, let compositor = self.compositor else {
            return
        }
        let now = CACurrentMediaTime()
        guard recorder.wantsVideoFrame(at: now) else {
            return
        }
        self.localImage = compositor.image(frame)
        // The own camera drives the file only while there is no remote video.
        if self.remoteImage == nil {
            self.composeFrame(at: now)
        }
    }

    private func composeFrame(at hostTime: Double) {
        guard let recorder = self.recorder, recorder.kind == .video, let compositor = self.compositor, let pool = recorder.pixelBufferPool else {
            return
        }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let pixelBuffer = output else {
            return
        }
        if let remoteImage = self.remoteImage {
            compositor.render(main: remoteImage, inset: self.localImage, into: pixelBuffer)
        } else {
            compositor.render(main: self.localImage, inset: nil, into: pixelBuffer)
        }
        recorder.appendVideo(pixelBuffer, hostTime: hostTime)
    }

    private func finishSegment() {
        guard let recorder = self.recorder else {
            return
        }
        self.recorder = nil
        let startDate = self.recorderStartDate
        let accountId = self.context.account.id.gg
        let peerKey = self.peerKey
        let peerTitle = self.peerTitle
        if recorder.duration < 1.0 {
            recorder.cancel()
            return
        }
        recorder.finish(completion: { success in
            let url = recorder.url
            guard success else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let item = GGCallRecordingItem(id: UUID().uuidString, fileName: url.lastPathComponent, kind: recorder.kind == .video ? .video : .audio, peer: peerKey, peerTitle: peerTitle, startDate: startDate, duration: recorder.duration, size: size)
            Queue.mainQueue().async {
                var items = GGCallsMediaSettings.recordings.value(for: accountId)
                items.insert(item, at: 0)
                GGCallsMediaSettings.recordings.set(items, for: accountId)
            }
        })
    }
}

/// Where an account's call recordings live.
enum GGCallRecordingStorage {
    static func directory(basePath: String) -> String {
        return basePath + "/ghostgram/call-recordings"
    }

    static func fileName(date: Date, kind: GGCallRecorder.Kind) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let suffix = String(UUID().uuidString.prefix(6))
        return "call_\(formatter.string(from: date))_\(suffix).\(kind == .video ? "mp4" : "m4a")"
    }

    static func url(basePath: String, item: GGCallRecordingItem) -> URL {
        return URL(fileURLWithPath: GGCallRecordingStorage.directory(basePath: basePath)).appendingPathComponent(item.fileName)
    }
}
