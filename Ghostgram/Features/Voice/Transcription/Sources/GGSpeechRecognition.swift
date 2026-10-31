import Foundation
import AVFoundation
import Speech
import SwiftSignalKit
import UniversalMediaPlayer
import GGCore

/// A finished recognition: text, exact word timings, mean confidence 0…1.
public struct GGSpeechTranscript {
    public let text: String
    public let words: [GGTranscriptionWord]
    public let confidence: Float
    public let localeIdentifier: String
}

public enum GGSpeechError: Error {
    /// The user has not allowed speech recognition (or it is restricted on this device).
    case notAuthorized
    /// No recognizer for any candidate language, or the recognizer is offline without a local model.
    case unavailable
    /// The file has no audio track, or nothing was recognized.
    case noSpeech
    /// Download or recognition failed.
    case failed
}

/// Apple Speech over a voice message or a round video, read straight from the media file: PCM is
/// decoded on the fly (`SoftwareAudioSource`, FFmpeg — the same reader for Ogg/Opus and MP4), so no
/// intermediate m4a is written and nothing is left in the temporary directory.
///
/// On the device when the language has a local model (`supportsOnDeviceRecognition`); otherwise Apple's
/// server, which the owner allowed (decision 2026-10-21). The server accepts about a minute per request,
/// so there the audio goes in pieces of 55 s and the words keep their absolute times.
enum GGSpeechRecognition {
    static let sampleRate: Double = 48000.0
    static let serverPieceSeconds: Double = 55.0

    static func authorize() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                subscriber.putNext(true)
                subscriber.putCompletion()
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { status in
                    subscriber.putNext(status == .authorized)
                    subscriber.putCompletion()
                }
            default:
                subscriber.putNext(false)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    /// The language of Telegram's interface, then the device languages: at most two different
    /// languages, each mapped to a locale the recognizer supports (preferring the user's own region).
    static func candidateLocales(interfaceLanguage: String) -> [Locale] {
        let supported = Array(SFSpeechRecognizer.supportedLocales())
        var preferredIdentifiers: [String] = [interfaceLanguage]
        preferredIdentifiers.append(contentsOf: Locale.preferredLanguages)
        let currentRegion = GGSpeechRecognition.regionCode(of: Locale.current.identifier)

        var seenLanguages = Set<String>()
        var result: [Locale] = []
        for identifier in preferredIdentifiers {
            let language = GGSpeechRecognition.languageCode(of: identifier)
            if language.isEmpty || seenLanguages.contains(language) {
                continue
            }
            seenLanguages.insert(language)
            let matching = supported.filter { GGSpeechRecognition.languageCode(of: $0.identifier) == language }
            if matching.isEmpty {
                continue
            }
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if let exact = matching.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == normalized }) {
                result.append(exact)
            } else if let regional = matching.first(where: { GGSpeechRecognition.regionCode(of: $0.identifier) == currentRegion }) {
                result.append(regional)
            } else if let first = matching.sorted(by: { $0.identifier < $1.identifier }).first {
                result.append(first)
            }
            if result.count >= 2 {
                break
            }
        }
        return result
    }

    static func languageCode(of identifier: String) -> String {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map { String($0).lowercased() } ?? ""
    }

    static func regionCode(of identifier: String) -> String {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let last = parts.last, parts.count >= 2, last.count == 2 else {
            return ""
        }
        return last.uppercased()
    }

    /// Recognizes the file with the first candidate; if it is unsure (or heard nothing) and there is a
    /// second language, tries that one too and keeps the more confident result.
    static func recognize(path: String, interfaceLanguage: String) -> Signal<GGSpeechTranscript, GGSpeechError> {
        let locales = GGSpeechRecognition.candidateLocales(interfaceLanguage: interfaceLanguage)
        guard let first = locales.first else {
            return .fail(.unavailable)
        }
        let firstPass = GGSpeechRecognition.pass(path: path, locale: first)
        guard locales.count > 1 else {
            return firstPass
        }
        let second = locales[1]
        return firstPass
        |> map { transcript -> GGSpeechTranscript? in
            return transcript
        }
        |> `catch` { error -> Signal<GGSpeechTranscript?, GGSpeechError> in
            switch error {
            case .notAuthorized:
                return .fail(error)
            default:
                return .single(nil)
            }
        }
        |> mapToSignal { firstResult -> Signal<GGSpeechTranscript, GGSpeechError> in
            if let firstResult, firstResult.confidence >= 0.5 {
                return .single(firstResult)
            }
            return GGSpeechRecognition.pass(path: path, locale: second)
            |> map { secondResult -> GGSpeechTranscript in
                if let firstResult, firstResult.confidence >= secondResult.confidence {
                    return firstResult
                }
                return secondResult
            }
            |> `catch` { error -> Signal<GGSpeechTranscript, GGSpeechError> in
                if let firstResult {
                    return .single(firstResult)
                }
                return .fail(error)
            }
        }
    }

    private static func pass(path: String, locale: Locale) -> Signal<GGSpeechTranscript, GGSpeechError> {
        return Signal { subscriber in
            let pass = GGSpeechPass(path: path, locale: locale, completion: { result in
                switch result {
                case let .success(transcript):
                    subscriber.putNext(transcript)
                    subscriber.putCompletion()
                case let .failure(error):
                    subscriber.putError(error)
                }
            })
            pass.start()
            return ActionDisposable {
                pass.cancel()
            }
        }
    }
}

/// One recognition of one file with one locale. Everything runs on its own serial queue, including the
/// recognizer's callbacks; the reader decodes at most one piece ahead of the recognizer.
private final class GGSpeechPass {
    private static let queue = DispatchQueue(label: "org.ghostgram.speech", qos: .userInitiated)

    private let path: String
    private let locale: Locale
    private let completion: (Result<GGSpeechTranscript, GGSpeechError>) -> Void
    private let operationQueue: OperationQueue

    private var recognizer: SFSpeechRecognizer?
    private var source: SoftwareAudioSource?
    private var task: SFSpeechRecognitionTask?
    private var onDevice = false
    private var isFinished = false
    private var reachedEnd = false
    private var pieceIndex = 0
    private var pieceOffset: Double = 0.0
    private var currentPieceStart: Double = 0.0
    private var pendingSamples = Data()

    private var text = ""
    private var words: [GGTranscriptionWord] = []
    private var confidenceSum: Float = 0.0
    private var confidenceCount = 0

    init(path: String, locale: Locale, completion: @escaping (Result<GGSpeechTranscript, GGSpeechError>) -> Void) {
        self.path = path
        self.locale = locale
        self.completion = completion
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = GGSpeechPass.queue
        self.operationQueue = operationQueue
    }

    func start() {
        GGSpeechPass.queue.async {
            guard let recognizer = SFSpeechRecognizer(locale: self.locale) else {
                self.finish(.failure(.unavailable))
                return
            }
            self.onDevice = recognizer.supportsOnDeviceRecognition
            guard self.onDevice || recognizer.isAvailable else {
                self.finish(.failure(.unavailable))
                return
            }
            recognizer.queue = self.operationQueue
            recognizer.defaultTaskHint = .dictation
            self.recognizer = recognizer
            let source = SoftwareAudioSource(path: self.path)
            guard source.hasStream else {
                self.finish(.failure(.noSpeech))
                return
            }
            self.source = source
            self.startPiece()
        }
    }

    func cancel() {
        GGSpeechPass.queue.async {
            self.isFinished = true
            self.task?.cancel()
            self.task = nil
            self.source = nil
        }
    }

    private func finish(_ result: Result<GGSpeechTranscript, GGSpeechError>) {
        if self.isFinished {
            return
        }
        self.isFinished = true
        self.task = nil
        self.source = nil
        self.completion(result)
    }

    private func startPiece() {
        guard !self.isFinished, let recognizer = self.recognizer, let source = self.source else {
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = self.onDevice
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        let pieceIndex = self.pieceIndex
        self.task = recognizer.recognitionTask(with: request, resultHandler: { [weak self] result, error in
            guard let self, !self.isFinished, self.pieceIndex == pieceIndex else {
                return
            }
            if let result, result.isFinal {
                self.append(result.bestTranscription)
                self.pieceFinished()
            } else if error != nil {
                // Silence in a piece is reported as an error; what was recognized so far stays.
                self.pieceFinished()
            }
        })

        self.currentPieceStart = self.pieceOffset
        let limit = self.onDevice ? Int.max : Int(GGSpeechRecognition.serverPieceSeconds * GGSpeechRecognition.sampleRate)
        var fed = 0
        let blockSamples = Int(GGSpeechRecognition.sampleRate)
        while fed < limit {
            if self.pendingSamples.isEmpty {
                guard let frame = source.readFrame() else {
                    self.reachedEnd = true
                    break
                }
                self.pendingSamples = frame
            }
            let available = self.pendingSamples.count / 2
            let take = min(available, min(blockSamples, limit - fed))
            if take <= 0 {
                self.pendingSamples = Data()
                continue
            }
            if let buffer = GGSpeechPass.makeBuffer(from: self.pendingSamples, sampleCount: take) {
                request.append(buffer)
            }
            fed += take
            if take == available {
                self.pendingSamples = Data()
            } else {
                self.pendingSamples = self.pendingSamples.subdata(in: (take * 2) ..< self.pendingSamples.count)
            }
        }
        request.endAudio()
        self.pieceOffset += Double(fed) / GGSpeechRecognition.sampleRate

        // A recognizer that never answers must not keep the bubble spinning forever.
        let timeout = max(30.0, Double(fed) / GGSpeechRecognition.sampleRate * 2.0 + 30.0)
        GGSpeechPass.queue.asyncAfter(deadline: .now() + timeout, execute: { [weak self] in
            guard let self, !self.isFinished, self.pieceIndex == pieceIndex else {
                return
            }
            self.task?.cancel()
            self.pieceFinished()
        })
    }

    private func pieceFinished() {
        self.pieceIndex += 1
        self.task = nil
        if self.reachedEnd && self.pendingSamples.isEmpty {
            if self.text.isEmpty {
                self.finish(.failure(.noSpeech))
            } else {
                let confidence = self.confidenceCount == 0 ? 0.0 : self.confidenceSum / Float(self.confidenceCount)
                self.finish(.success(GGSpeechTranscript(text: self.text, words: self.words, confidence: confidence, localeIdentifier: self.locale.identifier)))
            }
        } else {
            self.startPiece()
        }
    }

    /// Appends one piece's text and words; word times are absolute (the piece's start is added).
    private func append(_ transcription: SFTranscription) {
        let pieceText = transcription.formattedString
        if pieceText.isEmpty {
            return
        }
        var textOffset = (self.text as NSString).length
        if !self.text.isEmpty {
            self.text.append(" ")
            textOffset += 1
        }
        self.text.append(pieceText)
        let pieceStart = self.currentPieceStart
        for segment in transcription.segments {
            let range = segment.substringRange
            if range.location == NSNotFound || range.length <= 0 {
                continue
            }
            self.words.append(GGTranscriptionWord(location: textOffset + range.location, length: range.length, start: pieceStart + segment.timestamp, duration: segment.duration))
            self.confidenceSum += segment.confidence
            self.confidenceCount += 1
        }
    }

    private static func makeBuffer(from data: Data, sampleCount: Int) -> AVAudioPCMBuffer? {
        guard sampleCount > 0, let format = AVAudioFormat(standardFormatWithSampleRate: GGSpeechRecognition.sampleRate, channels: 1), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)), let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { raw in
            guard let samples = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return
            }
            let scale: Float = 1.0 / 32768.0
            for i in 0 ..< sampleCount {
                channel[i] = Float(samples[i]) * scale
            }
        }
        return buffer
    }
}
