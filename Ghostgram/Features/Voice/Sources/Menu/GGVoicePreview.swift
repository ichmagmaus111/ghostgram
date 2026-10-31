import Foundation
import UIKit
import AVFoundation
import SwiftSignalKit
import AccountContext
import TelegramAudio
import TelegramPresentationData
import GGCore
import GGSettingsUI
import GGFeaturesShared
import GGVoiceDSP

/// The built-in sample of the «Голос» tab: a phrase synthesized on the device (`AVSpeechSynthesizer`, no
/// network, nothing bundled) followed, when the equalizer is on, by a short synthetic music phrase
/// (bass, chord, hi-hat) that makes every band audible. It is processed offline by the same C graph and
/// the same equalizer as the real paths, so what is heard is what will be sent and played.
final class GGVoicePreviewPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = GGVoicePreviewPlayer()

    private struct Sample {
        let language: String
        let samples: [Float]
        let sampleRate: Double
    }

    private var cachedSample: Sample?
    private var synthesizer: AVSpeechSynthesizer?
    private var player: AVAudioPlayer?
    private var audioSessionDisposable: Disposable?
    private let isPlayingPromise = ValuePromise<Bool>(false, ignoreRepeated: true)

    var isPlaying: Signal<Bool, NoError> {
        return self.isPlayingPromise.get()
    }

    /// `processed`: the selected preset (even with the voice changer off — so it can be heard before
    /// switching on) and the equalizer if it is on. Otherwise the untouched sample, to compare.
    func play(context: AccountContext, processed: Bool) {
        self.stop()
        let language = GGLocalization.shared.languageCode
        self.loadSample(language: language, completion: { [weak self] sample in
            guard let self, let sample else {
                return
            }
            var samples = sample.samples
            let sampleRate = sample.sampleRate
            if processed {
                GGVoicePreviewPlayer.applyVoice(&samples, sampleRate: sampleRate)
            }
            GGVoicePreviewPlayer.appendMusicIfNeeded(&samples, sampleRate: sampleRate)
            if processed, let gains = GGVoiceEqualizer.previewGains() {
                gains.withUnsafeBufferPointer { gainsBuffer in
                    samples.withUnsafeMutableBufferPointer { buffer in
                        if let gainsBase = gainsBuffer.baseAddress, let base = buffer.baseAddress {
                            GGAudioEqualizerProcessOffline(gainsBase, base, buffer.count, UInt32(sampleRate))
                        }
                    }
                }
            }
            let data = GGVoicePreviewPlayer.wavData(samples, sampleRate: sampleRate)
            self.startPlayback(context: context, data: data)
        })
    }

    func stop() {
        self.player?.stop()
        self.player = nil
        self.audioSessionDisposable?.dispose()
        self.audioSessionDisposable = nil
        self.isPlayingPromise.set(false)
    }

    private func startPlayback(context: AccountContext, data: Data) {
        guard let player = try? AVAudioPlayer(data: data) else {
            return
        }
        player.delegate = self
        self.player = player
        self.isPlayingPromise.set(true)
        self.audioSessionDisposable = context.sharedContext.mediaManager.audioSession.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self, weak player] _ in
            Queue.mainQueue().async {
                guard let self, let player, self.player === player else {
                    return
                }
                player.play()
            }
        }, deactivate: { [weak self] _ in
            Queue.mainQueue().async {
                self?.stop()
            }
            return .complete()
        })
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Queue.mainQueue().async {
            if self.player === player {
                self.stop()
            }
        }
    }

    // MARK: Sample

    private func loadSample(language: String, completion: @escaping (Sample?) -> Void) {
        if let cachedSample = self.cachedSample, cachedSample.language == language {
            completion(cachedSample)
            return
        }
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: GGStrings.Voice.Preview.phrase)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        var samples: [Float] = []
        var sampleRate: Double = 0.0
        var finished = false
        synthesizer.write(utterance, toBufferCallback: { [weak self] buffer in
            guard !finished else {
                return
            }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                finished = true
                Queue.mainQueue().async {
                    guard let self else {
                        return
                    }
                    self.synthesizer = nil
                    if samples.isEmpty || sampleRate <= 0.0 {
                        completion(GGVoicePreviewPlayer.syntheticVoice(language: language))
                        return
                    }
                    let sample = Sample(language: language, samples: samples, sampleRate: sampleRate)
                    self.cachedSample = sample
                    completion(sample)
                }
                return
            }
            sampleRate = pcm.format.sampleRate
            let frames = Int(pcm.frameLength)
            if let floats = pcm.floatChannelData {
                for i in 0 ..< frames {
                    samples.append(floats[0][i])
                }
            } else if let ints = pcm.int16ChannelData {
                for i in 0 ..< frames {
                    samples.append(Float(ints[0][i]) / 32768.0)
                }
            }
        })
    }

    /// Fallback when no voice is installed: a vowel-like tone with a moving pitch, still enough to hear
    /// pitch, timbre and the effects.
    private static func syntheticVoice(language: String) -> Sample {
        let sampleRate = 24000.0
        let count = Int(sampleRate * 2.4)
        var samples = [Float](repeating: 0.0, count: count)
        var phase = 0.0
        for i in 0 ..< count {
            let t = Double(i) / sampleRate
            let syllable = sin(.pi * (t.truncatingRemainder(dividingBy: 0.4)) / 0.4)
            let pitch = 140.0 + 30.0 * sin(2.0 * .pi * 0.8 * t)
            phase += 2.0 * .pi * pitch / sampleRate
            var value = 0.0
            for harmonic in 1 ... 12 {
                let h = Double(harmonic)
                let formant = exp(-pow((h * pitch - 700.0) / 400.0, 2.0)) + 0.6 * exp(-pow((h * pitch - 1200.0) / 500.0, 2.0)) + 0.15
                value += sin(phase * h) * formant / h
            }
            samples[i] = Float(value * 0.25 * syllable)
        }
        return Sample(language: language, samples: samples, sampleRate: sampleRate)
    }

    private static func applyVoice(_ samples: inout [Float], sampleRate: Double) {
        var params = GGVoicePresets.params(for: GGVoicePresets.selectedPreset)
        if GGVoiceParamsIsIdentity(&params) {
            return
        }
        let rate = UInt32(max(8000.0, min(96000.0, sampleRate)))
        guard let chain = GGVoiceChainCreate(&params, rate) else {
            return
        }
        defer {
            GGVoiceChainDestroy(chain)
        }
        samples.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                GGVoiceChainProcessFloat(chain, base, buffer.count, 1, rate)
            }
        }
    }

    private static func appendMusicIfNeeded(_ samples: inout [Float], sampleRate: Double) {
        guard GGVoiceEqualizer.previewGains() != nil else {
            return
        }
        let gap = Int(sampleRate * 0.3)
        samples.append(contentsOf: [Float](repeating: 0.0, count: gap))
        let count = Int(sampleRate * 2.0)
        var rng: UInt32 = 0x12345678
        for i in 0 ..< count {
            let t = Double(i) / sampleRate
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let bass = sin(2.0 * .pi * 55.0 * t) * exp(-beat * 6.0) * 0.5
            let chord = (sin(2.0 * .pi * 220.0 * t) + sin(2.0 * .pi * 277.18 * t) + sin(2.0 * .pi * 329.63 * t)) * 0.08
            rng ^= rng << 13
            rng ^= rng >> 17
            rng ^= rng << 5
            let noise = (Double(rng) / Double(UInt32.max)) * 2.0 - 1.0
            let hatPhase = t.truncatingRemainder(dividingBy: 0.25)
            let hat = noise * exp(-hatPhase * 60.0) * 0.12
            samples.append(Float(bass + chord + hat))
        }
    }

    private static func wavData(_ samples: [Float], sampleRate: Double) -> Data {
        var peak: Float = 0.0
        for value in samples {
            peak = max(peak, abs(value))
        }
        let scale: Float = peak > 0.0 ? min(4.0, 0.9 / peak) : 1.0
        let rate = UInt32(sampleRate)
        var data = Data()
        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(rate)
        appendUInt32(rate * 2)
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(byteCount)
        data.reserveCapacity(data.count + samples.count * 2)
        for value in samples {
            let scaled = max(-1.0, min(1.0, value * scale))
            appendUInt16(UInt16(bitPattern: Int16(scaled * 32767.0)))
        }
        return data
    }
}

/// The preview row: «Прослушать» (with the current preset and equalizer) and «Без эффектов».
final class GGVoicePreviewView: UIView, GGMenuPreviewView {
    private let titleLabel = UILabel()
    private let infoLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let originalButton = UIButton(type: .system)
    private var context: AccountContext?
    private var isPlayingDisposable: Disposable?
    private var isPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.titleLabel.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.infoLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.infoLabel.numberOfLines = 2
        self.playButton.titleLabel?.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
        self.playButton.layer.cornerRadius = 12.0
        self.playButton.clipsToBounds = true
        self.originalButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0)
        self.addSubview(self.titleLabel)
        self.addSubview(self.infoLabel)
        self.addSubview(self.playButton)
        self.addSubview(self.originalButton)
        self.playButton.addTarget(self, action: #selector(self.playPressed), for: .touchUpInside)
        self.originalButton.addTarget(self, action: #selector(self.originalPressed), for: .touchUpInside)
        self.isPlayingDisposable = (GGVoicePreviewPlayer.shared.isPlaying
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else {
                return
            }
            self.isPlaying = value
            self.updateTitles()
        })
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        self.isPlayingDisposable?.dispose()
    }

    func update(context: GGMenuContext) {
        self.context = context.context
        let theme = context.presentationData.theme
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.infoLabel.textColor = theme.list.itemSecondaryTextColor
        self.playButton.backgroundColor = theme.list.itemCheckColors.fillColor
        self.playButton.setTitleColor(theme.list.itemCheckColors.foregroundColor, for: .normal)
        self.originalButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.titleLabel.text = GGVoicePresets.selectedPreset.title
        var info: [String] = []
        info.append(GGVoiceSettings.morphEnabled.value ? GGStrings.Voice.Preview.morphOn : GGStrings.Voice.Preview.morphOff)
        if GGVoiceEqualizer.previewGains() != nil {
            info.append(GGStrings.Voice.Preview.eqOn)
        }
        self.infoLabel.text = info.joined(separator: " · ")
        self.updateTitles()
        self.setNeedsLayout()
    }

    private func updateTitles() {
        self.playButton.setTitle(self.isPlaying ? GGStrings.Voice.Preview.stop : GGStrings.Voice.Preview.play, for: .normal)
        self.originalButton.setTitle(GGStrings.Voice.Preview.original, for: .normal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 16.0
        let width = self.bounds.width - inset * 2.0
        self.titleLabel.frame = CGRect(x: inset, y: 14.0, width: width, height: 22.0)
        self.infoLabel.frame = CGRect(x: inset, y: 38.0, width: width, height: 34.0)
        let buttonY = self.bounds.height - 14.0 - 44.0
        let originalWidth: CGFloat = min(140.0, width * 0.4)
        self.playButton.frame = CGRect(x: inset, y: buttonY, width: width - originalWidth - 8.0, height: 44.0)
        self.originalButton.frame = CGRect(x: inset + width - originalWidth, y: buttonY, width: originalWidth, height: 44.0)
    }

    @objc private func playPressed() {
        guard let context = self.context else {
            return
        }
        if self.isPlaying {
            GGVoicePreviewPlayer.shared.stop()
        } else {
            GGVoicePreviewPlayer.shared.play(context: context, processed: true)
        }
    }

    @objc private func originalPressed() {
        guard let context = self.context else {
            return
        }
        GGVoicePreviewPlayer.shared.play(context: context, processed: false)
    }
}
