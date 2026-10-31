#import <GGCallAudio/GGCallAudio.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>

namespace {

// Larger than any block the device delivers (10 ms of 48 kHz stereo is 960 samples); a bigger block
// passes through unprocessed rather than being cut.
constexpr size_t kScratchSamples = 8192;
// Mono samples per recording ring, a power of two: ≈ 10.9 s at 48 kHz, 1 MB.
constexpr uint64_t kRingCapacity = uint64_t(1) << 19;
constexpr uint64_t kRingMask = kRingCapacity - 1;
// Microphone gain while a clip plays with "duck the microphone".
constexpr float kDuckGain = 0.25f;

inline int16_t clampSample(float value) {
    if (value > 32767.0f) {
        return 32767;
    }
    if (value < -32768.0f) {
        return -32768;
    }
    return (int16_t)value;
}

struct Clip {
    std::vector<int16_t> samples;
    double sampleRate = 48000.0;
    float volume = 1.0f;
    bool duck = false;
    uint64_t generation = 0;
};

/// Single producer (the realtime thread) / single consumer (the drain under the control lock).
struct Ring {
    std::unique_ptr<int16_t[]> buffer;
    std::atomic<uint64_t> writeIndex{0};
    std::atomic<uint64_t> readIndex{0};
    std::atomic<uint32_t> sampleRate{0};
    std::atomic<int64_t> dropped{0};

    Ring() : buffer(new int16_t[kRingCapacity]) {
    }

    /// Realtime. Mono downmix; a block that does not fit is dropped whole (the consumer is late).
    void write(const int16_t *samples, size_t frames, size_t channels, uint32_t rate) {
        uint64_t write = this->writeIndex.load(std::memory_order_relaxed);
        uint64_t read = this->readIndex.load(std::memory_order_acquire);
        if (write - read + frames > kRingCapacity) {
            this->dropped.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        this->sampleRate.store(rate, std::memory_order_relaxed);
        int16_t *buffer = this->buffer.get();
        if (channels == 1) {
            for (size_t i = 0; i < frames; i++) {
                buffer[(write + i) & kRingMask] = samples[i];
            }
        } else {
            for (size_t i = 0; i < frames; i++) {
                int32_t sum = 0;
                for (size_t c = 0; c < channels; c++) {
                    sum += samples[i * channels + c];
                }
                buffer[(write + i) & kRingMask] = (int16_t)(sum / (int32_t)channels);
            }
        }
        this->writeIndex.store(write + frames, std::memory_order_release);
    }

    size_t available() const {
        return (size_t)(this->writeIndex.load(std::memory_order_acquire) - this->readIndex.load(std::memory_order_relaxed));
    }

    void read(int16_t *output, size_t count) {
        uint64_t read = this->readIndex.load(std::memory_order_relaxed);
        const int16_t *buffer = this->buffer.get();
        for (size_t i = 0; i < count; i++) {
            output[i] = buffer[(read + i) & kRingMask];
        }
        this->readIndex.store(read + count, std::memory_order_release);
    }

    void skip(size_t count) {
        uint64_t read = this->readIndex.load(std::memory_order_relaxed);
        this->readIndex.store(read + count, std::memory_order_release);
    }
};

struct Tap {
    Ring remote;
    std::unique_ptr<Ring> microphone;
};

struct EffectBox {
    GGCallCaptureEffect effect;
};

struct Retired {
    uint64_t epoch;
    std::function<void()> free;
};

}

struct GGCallAudioCore {
    std::atomic<int32_t> refCount{1};

    std::atomic<bool> silenced{false};
    std::atomic<Clip *> clip{nullptr};
    std::atomic<uint64_t> finishedClipGeneration{0};
    std::atomic<Tap *> tap{nullptr};
    std::atomic<EffectBox *> effect{nullptr};

    // Realtime callbacks entered and left. The device module serializes them, so a retired object is
    // unreachable once `left` reaches the `entered` value read right after it was unpublished.
    std::atomic<uint64_t> entered{0};
    std::atomic<uint64_t> left{0};

    // Realtime thread only.
    uint64_t rtClipGeneration = 0;
    double rtClipPosition = 0.0;
    int16_t scratch[kScratchSamples];

    // Control side, under `controlLock`.
    std::mutex controlLock;
    std::vector<Retired> retired;
    uint64_t nextClipGeneration = 1;
    uint64_t currentClipGeneration = 0;

    ~GGCallAudioCore() {
        // No realtime callback can run any more: the device module holds a reference until it is gone.
        for (auto &item : this->retired) {
            item.free();
        }
        this->retired.clear();
        delete this->clip.exchange(nullptr);
        delete this->tap.exchange(nullptr);
        if (EffectBox *box = this->effect.exchange(nullptr)) {
            if (box->effect.release) {
                box->effect.release(box->effect.context);
            }
            delete box;
        }
    }

    // Must hold `controlLock`; call right after the object was unpublished.
    void retireLocked(std::function<void()> free) {
        uint64_t epoch = this->entered.load(std::memory_order_seq_cst);
        this->retired.push_back(Retired{epoch, std::move(free)});
        this->collectLocked();
    }

    void collectLocked() {
        if (this->retired.empty()) {
            return;
        }
        uint64_t left = this->left.load(std::memory_order_seq_cst);
        std::vector<Retired> keep;
        for (auto &item : this->retired) {
            if (left >= item.epoch) {
                item.free();
            } else {
                keep.push_back(std::move(item));
            }
        }
        this->retired = std::move(keep);
    }

    void retireClipLocked(Clip *clip) {
        if (clip) {
            this->retireLocked([clip]() {
                delete clip;
            });
        }
    }

    void retireTapLocked(Tap *tap) {
        if (tap) {
            this->retireLocked([tap]() {
                delete tap;
            });
        }
    }

    void retireEffectLocked(EffectBox *box) {
        if (box) {
            this->retireLocked([box]() {
                if (box->effect.release) {
                    box->effect.release(box->effect.context);
                }
                delete box;
            });
        }
    }
};

namespace {

/// Realtime. Mixes the clip into `output` and advances the realtime position; marks the clip finished
/// once its last sample has been played.
void mixClip(GGCallAudioCore *core, const Clip *clip, int16_t *output, size_t frames, size_t channels, uint32_t sampleRate, bool silenced) {
    const size_t count = clip->samples.size();
    const double step = clip->sampleRate / (double)sampleRate;
    const float micGain = (clip->duck && !silenced) ? kDuckGain : 1.0f;
    const int16_t *samples = clip->samples.data();
    double position = core->rtClipPosition;
    for (size_t i = 0; i < frames; i++) {
        float clipValue = 0.0f;
        if (position < (double)count) {
            size_t index = (size_t)position;
            float fraction = (float)(position - (double)index);
            float a = (float)samples[index];
            float b = index + 1 < count ? (float)samples[index + 1] : a;
            clipValue = (a + (b - a) * fraction) * clip->volume;
            position += step;
        }
        for (size_t c = 0; c < channels; c++) {
            size_t sampleIndex = i * channels + c;
            output[sampleIndex] = clampSample((float)output[sampleIndex] * micGain + clipValue);
        }
    }
    core->rtClipPosition = position;
    if (position >= (double)count) {
        core->finishedClipGeneration.store(clip->generation, std::memory_order_release);
    }
}

}

extern "C" void GGCallAudioCoreRetain(GGCallAudioCore *core) {
    if (core) {
        core->refCount.fetch_add(1, std::memory_order_relaxed);
    }
}

extern "C" void GGCallAudioCoreRelease(GGCallAudioCore *core) {
    if (core && core->refCount.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        delete core;
    }
}

extern "C" const int16_t *GGCallAudioCoreProcessCapture(GGCallAudioCore *core, const int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate) {
    if (core == nullptr || samples == nullptr || frames == 0 || channels == 0) {
        return samples;
    }
    core->entered.fetch_add(1, std::memory_order_seq_cst);

    const int16_t *result = samples;
    const bool silenced = core->silenced.load(std::memory_order_relaxed);
    EffectBox *effect = core->effect.load(std::memory_order_seq_cst);
    Clip *clip = core->clip.load(std::memory_order_seq_cst);

    bool clipActive = false;
    if (clip != nullptr) {
        if (clip->generation != core->rtClipGeneration) {
            core->rtClipGeneration = clip->generation;
            core->rtClipPosition = 0.0;
        }
        clipActive = core->finishedClipGeneration.load(std::memory_order_acquire) != clip->generation;
    }

    const size_t total = frames * channels;
    if ((silenced || effect != nullptr || clipActive) && total <= kScratchSamples && sampleRate != 0) {
        int16_t *output = core->scratch;
        if (silenced) {
            memset(output, 0, total * sizeof(int16_t));
        } else {
            memcpy(output, samples, total * sizeof(int16_t));
            if (effect != nullptr) {
                effect->effect.process(effect->effect.context, output, frames, channels, sampleRate);
            }
        }
        if (clipActive) {
            mixClip(core, clip, output, frames, channels, sampleRate, silenced);
        }
        result = output;
    }

    Tap *tap = core->tap.load(std::memory_order_seq_cst);
    if (tap != nullptr && tap->microphone && sampleRate != 0) {
        tap->microphone->write(result, frames, channels, sampleRate);
    }

    core->left.fetch_add(1, std::memory_order_seq_cst);
    return result;
}

extern "C" void GGCallAudioCoreTapPlayout(GGCallAudioCore *core, const int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate) {
    if (core == nullptr || samples == nullptr || frames == 0 || channels == 0 || sampleRate == 0) {
        return;
    }
    core->entered.fetch_add(1, std::memory_order_seq_cst);
    Tap *tap = core->tap.load(std::memory_order_seq_cst);
    if (tap != nullptr) {
        tap->remote.write(samples, frames, channels, sampleRate);
    }
    core->left.fetch_add(1, std::memory_order_seq_cst);
}

@implementation GGCallAudioRecordingChunk

- (instancetype)initWithSamples:(NSData *)samples sampleRate:(int32_t)sampleRate {
    self = [super init];
    if (self != nil) {
        _samples = samples;
        _sampleRate = sampleRate;
    }
    return self;
}

@end

@implementation GGCallAudioEffects {
    GGCallAudioCore *_core;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _core = new GGCallAudioCore();
    }
    return self;
}

- (void)dealloc {
    GGCallAudioCoreRelease(_core);
}

- (GGCallAudioCore *)core {
    return _core;
}

- (bool)captureSilenced {
    return _core->silenced.load(std::memory_order_relaxed);
}

- (void)setCaptureSilenced:(bool)captureSilenced {
    _core->silenced.store(captureSilenced, std::memory_order_relaxed);
}

- (void)playClip:(NSData *)samples sampleRate:(int32_t)sampleRate volume:(float)volume duckMicrophone:(bool)duckMicrophone {
    size_t count = samples.length / sizeof(int16_t);
    if (count == 0 || sampleRate <= 0) {
        [self stopClip];
        return;
    }
    Clip *clip = new Clip();
    clip->samples.resize(count);
    memcpy(clip->samples.data(), samples.bytes, count * sizeof(int16_t));
    clip->sampleRate = (double)sampleRate;
    clip->volume = std::max(0.0f, std::min(1.0f, volume));
    clip->duck = duckMicrophone;

    std::lock_guard<std::mutex> lock(_core->controlLock);
    clip->generation = _core->nextClipGeneration;
    _core->nextClipGeneration += 1;
    _core->currentClipGeneration = clip->generation;
    Clip *previous = _core->clip.exchange(clip, std::memory_order_seq_cst);
    _core->retireClipLocked(previous);
}

- (void)stopClip {
    std::lock_guard<std::mutex> lock(_core->controlLock);
    _core->currentClipGeneration = 0;
    Clip *previous = _core->clip.exchange(nullptr, std::memory_order_seq_cst);
    _core->retireClipLocked(previous);
}

- (bool)isClipPlaying {
    std::lock_guard<std::mutex> lock(_core->controlLock);
    _core->collectLocked();
    if (_core->currentClipGeneration == 0) {
        return false;
    }
    return _core->finishedClipGeneration.load(std::memory_order_acquire) != _core->currentClipGeneration;
}

- (void)startRecordingIncludingMicrophone:(bool)includeMicrophone {
    Tap *tap = new Tap();
    if (includeMicrophone) {
        tap->microphone.reset(new Ring());
    }
    std::lock_guard<std::mutex> lock(_core->controlLock);
    Tap *previous = _core->tap.exchange(tap, std::memory_order_seq_cst);
    _core->retireTapLocked(previous);
}

- (GGCallAudioRecordingChunk * _Nullable)drainRecording {
    std::lock_guard<std::mutex> lock(_core->controlLock);
    _core->collectLocked();
    Tap *tap = _core->tap.load(std::memory_order_seq_cst);
    if (tap == nullptr) {
        return nil;
    }
    Ring *microphone = tap->microphone.get();

    size_t remoteCount = tap->remote.available();
    uint32_t remoteRate = tap->remote.sampleRate.load(std::memory_order_relaxed);
    size_t microphoneCount = microphone ? microphone->available() : 0;
    uint32_t microphoneRate = microphone ? microphone->sampleRate.load(std::memory_order_relaxed) : 0;

    if (remoteCount == 0) {
        // Playout stalled (route change, interruption): keep the microphone moving once it has piled up.
        if (microphone && microphoneRate != 0 && microphoneCount > (size_t)microphoneRate / 2) {
            NSMutableData *data = [[NSMutableData alloc] initWithLength:microphoneCount * sizeof(int16_t)];
            microphone->read((int16_t *)data.mutableBytes, microphoneCount);
            return [[GGCallAudioRecordingChunk alloc] initWithSamples:data sampleRate:(int32_t)microphoneRate];
        }
        return nil;
    }
    if (remoteRate == 0) {
        remoteRate = 48000;
    }

    NSMutableData *data = [[NSMutableData alloc] initWithLength:remoteCount * sizeof(int16_t)];
    int16_t *output = (int16_t *)data.mutableBytes;
    tap->remote.read(output, remoteCount);

    if (microphone && microphoneCount != 0) {
        if (microphoneRate == 0) {
            microphoneRate = remoteRate;
        }
        // The microphone samples that cover the same time as the remote block.
        size_t wanted = (size_t)((double)remoteCount * (double)microphoneRate / (double)remoteRate);
        // Drift guard: never let the microphone run more than half a second ahead of the remote side.
        size_t slack = (size_t)microphoneRate / 2;
        if (microphoneCount > wanted + slack) {
            microphone->skip(microphoneCount - wanted - slack);
            microphoneCount = wanted + slack;
        }
        size_t take = std::min(wanted, microphoneCount);
        if (take != 0) {
            std::vector<int16_t> mic(take);
            microphone->read(mic.data(), take);
            if (microphoneRate == remoteRate) {
                for (size_t i = 0; i < take && i < remoteCount; i++) {
                    output[i] = clampSample((float)output[i] + (float)mic[i]);
                }
            } else {
                double step = (double)microphoneRate / (double)remoteRate;
                double position = 0.0;
                for (size_t i = 0; i < remoteCount; i++) {
                    size_t index = (size_t)position;
                    if (index >= take) {
                        break;
                    }
                    float fraction = (float)(position - (double)index);
                    float a = (float)mic[index];
                    float b = index + 1 < take ? (float)mic[index + 1] : a;
                    output[i] = clampSample((float)output[i] + a + (b - a) * fraction);
                    position += step;
                }
            }
        }
    }
    return [[GGCallAudioRecordingChunk alloc] initWithSamples:data sampleRate:(int32_t)remoteRate];
}

- (void)stopRecording {
    std::lock_guard<std::mutex> lock(_core->controlLock);
    Tap *previous = _core->tap.exchange(nullptr, std::memory_order_seq_cst);
    _core->retireTapLocked(previous);
}

- (bool)isRecording {
    return _core->tap.load(std::memory_order_seq_cst) != nullptr;
}

- (int64_t)droppedRecordingBlocks {
    std::lock_guard<std::mutex> lock(_core->controlLock);
    Tap *tap = _core->tap.load(std::memory_order_seq_cst);
    if (tap == nullptr) {
        return 0;
    }
    int64_t result = tap->remote.dropped.load(std::memory_order_relaxed);
    if (tap->microphone) {
        result += tap->microphone->dropped.load(std::memory_order_relaxed);
    }
    return result;
}

- (void)setCaptureEffect:(GGCallCaptureEffect const * _Nullable)effect {
    EffectBox *box = nullptr;
    if (effect != nullptr && effect->process != nullptr) {
        box = new EffectBox();
        box->effect = *effect;
    }
    std::lock_guard<std::mutex> lock(_core->controlLock);
    EffectBox *previous = _core->effect.exchange(box, std::memory_order_seq_cst);
    _core->retireEffectLocked(previous);
}

- (void)reset {
    _core->silenced.store(false, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(_core->controlLock);
    _core->currentClipGeneration = 0;
    _core->retireClipLocked(_core->clip.exchange(nullptr, std::memory_order_seq_cst));
    _core->retireTapLocked(_core->tap.exchange(nullptr, std::memory_order_seq_cst));
    _core->retireEffectLocked(_core->effect.exchange(nullptr, std::memory_order_seq_cst));
}

@end
