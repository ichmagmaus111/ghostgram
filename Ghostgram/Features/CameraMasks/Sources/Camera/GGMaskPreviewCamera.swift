import Foundation
import UIKit
import GGCore
import AVFoundation
import CoreImage
import GGCameraPipeline

/// The live front camera of the menu previews and the studio: 1280×720, the mask applied by the
/// same processor the round videos use. It runs only while its view is in a window and was started
/// (the settings tab: by the «Show» button; the studio: when the editor is on screen) and stops
/// when the view leaves the window or the app goes to the background.
final class GGMaskPreviewCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable {
        case idle
        case running
        case denied
        case unavailable
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.ghostgram.masks.previewCamera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var isConfigured = false
    let processor: GGMaskFrameProcessor
    private weak var view: GGProcessedFrameView?
    private var snapshotRequest: ((UIImage?) -> Void)?
    private let snapshotLock = NSLock()

    var stateChanged: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet {
            if self.state != oldValue {
                let state = self.state
                DispatchQueue.main.async { [weak self] in
                    self?.stateChanged?(state)
                }
            }
        }
    }

    init(maskProvider: @escaping () -> GGPreparedMask?) {
        self.processor = GGMaskFrameProcessor(maskProvider: maskProvider)
        super.init()
    }

    func attach(to view: GGProcessedFrameView) {
        self.view = view
    }

    func start() {
        #if targetEnvironment(simulator)
        self.queue.async {
            self.state = .unavailable
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.queue.async {
                self.startSession()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { [weak self] granted in
                guard let self else {
                    return
                }
                self.queue.async {
                    if granted {
                        self.startSession()
                    } else {
                        self.state = .denied
                    }
                }
            })
        default:
            self.queue.async {
                self.state = .denied
            }
        }
        #endif
    }

    func stop() {
        self.queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.state = .idle
        }
    }

    private func startSession() {
        if !self.isConfigured {
            self.isConfigured = true
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1280x720) {
                self.session.sessionPreset = .hd1280x720
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front), let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                self.state = .unavailable
                return
            }
            self.session.addInput(input)
            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            self.output.alwaysDiscardsLateVideoFrames = true
            self.output.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }
            self.session.commitConfiguration()
        }
        if !self.session.isRunning {
            self.session.startRunning()
        }
        self.state = .running
    }

    /// The next masked frame as an image (the studio's preview frame of a mask).
    func takeSnapshot(_ completion: @escaping (UIImage?) -> Void) {
        self.snapshotLock.lock()
        self.snapshotRequest = completion
        self.snapshotLock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        // Portrait, front camera: turn right and mirror like a selfie.
        let info = GGCameraFrameInfo(facing: .front, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), orientation: GGCameraFrameInfo.orientation(quarterTurns: 1, mirrored: true))
        let processed = self.processor.process(pixelBuffer, info: info)
        let shown = processed ?? pixelBuffer
        self.view?.enqueue(shown, orientation: info.orientation)

        self.snapshotLock.lock()
        let request = self.snapshotRequest
        self.snapshotRequest = nil
        self.snapshotLock.unlock()
        if let request {
            let image = CIImage(cvPixelBuffer: shown).oriented(info.orientation)
            let cgImage = GGMaskRenderContext.shared.createCGImage(image, from: image.extent)
            DispatchQueue.main.async {
                request(cgImage.map { UIImage(cgImage: $0) })
            }
        }
    }
}

/// A preview block: the live camera inside, a «Show» button until it is started, a message when the
/// camera is not allowed. Stops the camera when it leaves the window.
final class GGMaskPreviewCameraView: UIView {
    let frameView = GGProcessedFrameView()
    let camera: GGMaskPreviewCamera
    private let startButton = UIButton(type: .system)
    private let messageLabel = UILabel()
    private let autoStart: Bool
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []
    /// An extra layer over the frames (the watermark preview).
    let overlayView = UIImageView()

    init(maskProvider: @escaping () -> GGPreparedMask?, autoStart: Bool) {
        self.camera = GGMaskPreviewCamera(maskProvider: maskProvider)
        self.autoStart = autoStart
        super.init(frame: .zero)
        self.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        self.clipsToBounds = true
        self.addSubview(self.frameView)
        self.overlayView.contentMode = .scaleAspectFill
        self.addSubview(self.overlayView)
        self.camera.attach(to: self.frameView)

        self.startButton.setTitle(GGStrings.CameraMasks.Preview.show, for: .normal)
        self.startButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        self.startButton.tintColor = .white
        self.startButton.backgroundColor = UIColor(white: 1.0, alpha: 0.18)
        self.startButton.layer.cornerRadius = 16.0
        self.startButton.addTarget(self, action: #selector(self.startPressed), for: .touchUpInside)
        self.addSubview(self.startButton)

        self.messageLabel.textColor = UIColor(white: 1.0, alpha: 0.85)
        self.messageLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.messageLabel.textAlignment = .center
        self.messageLabel.numberOfLines = 3
        self.messageLabel.isHidden = true
        self.addSubview(self.messageLabel)

        self.camera.stateChanged = { [weak self] state in
            self?.update(state: state)
        }
        self.startButton.isHidden = autoStart
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.camera.stop()
    }

    @objc private func startPressed() {
        self.wantsRunning = true
        self.startButton.isHidden = true
        self.camera.start()
    }

    private func update(state: GGMaskPreviewCamera.State) {
        switch state {
        case .denied:
            self.messageLabel.text = GGStrings.CameraMasks.Preview.cameraDenied
            self.messageLabel.isHidden = false
            self.startButton.isHidden = true
        case .unavailable:
            self.messageLabel.text = GGStrings.CameraMasks.Preview.unavailable
            self.messageLabel.isHidden = false
            self.startButton.isHidden = true
        case .running:
            self.messageLabel.isHidden = true
            self.startButton.isHidden = true
        case .idle:
            self.messageLabel.isHidden = true
            self.startButton.isHidden = self.autoStart || self.wantsRunning
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil {
            if self.observers.isEmpty {
                // UIApplication posts these on the main thread.
                self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
                    self?.camera.stop()
                }))
                self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main, using: { [weak self] _ in
                    guard let self, self.window != nil, self.wantsRunning || self.autoStart else {
                        return
                    }
                    self.camera.start()
                }))
            }
            if self.autoStart || self.wantsRunning {
                self.wantsRunning = true
                self.camera.start()
            }
        } else {
            self.camera.stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.frameView.frame = self.bounds
        self.overlayView.frame = self.bounds
        let fitted = self.startButton.sizeThatFits(self.bounds.size)
        let buttonSize = CGSize(width: fitted.width + 28.0, height: max(32.0, fitted.height + 12.0))
        self.startButton.frame = CGRect(x: (self.bounds.width - buttonSize.width) / 2.0, y: (self.bounds.height - buttonSize.height) / 2.0, width: buttonSize.width, height: buttonSize.height)
        self.messageLabel.frame = self.bounds.insetBy(dx: 16.0, dy: 8.0)
    }
}
