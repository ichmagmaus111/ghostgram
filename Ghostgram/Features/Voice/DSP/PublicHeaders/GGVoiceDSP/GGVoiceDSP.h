#ifndef GGVoiceDSP_h
#define GGVoiceDSP_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Native audio effects of the «Голос» zone, plain C, no Foundation.
//
// 1. The voice chain: ONE effect graph for voice messages (in the recorder), round videos (the audio
//    stage of the camera pipeline) and calls (the capture effect of the call audio device). It never
//    changes the number of samples: pitch is shifted with two crossfaded delay taps, there is no
//    tempo and no reverse, so the same preset sounds the same on all three paths.
// 2. The playback equalizer: 5 Float32 biquads per channel, shared parameters published through a
//    seqlock, one instance per audio renderer.
//
// Realtime rules (both): every buffer is allocated by `...Create`; the `...Process...` functions never
// allocate, lock, block, touch files or use Double, and keep the frame count of their input.

#pragma clang assume_nonnull begin

#ifdef __cplusplus
extern "C" {
#endif

/// Parameters of the voice chain, in user units. `GGVoiceParamsSetIdentity` gives the neutral set.
typedef struct GGVoiceParams {
    /// Pitch shift, semitones, −12…12.
    float pitchSemitones;
    /// Timbre (spectral tilt), −1 (darker) … 1 (brighter). Not a formant shift and not called one.
    float timbre;
    /// 3-band voice EQ, dB, −12…12: low shelf 200 Hz, peak 1 kHz, high shelf 4 kHz.
    float bassDb;
    float midDb;
    float trebleDb;
    /// Telephone band (300–3400 Hz), 0…1.
    float telephone;
    /// Soft-clip distortion, 0…1.
    float distortion;
    /// Bit depth 2…16; 16 = off.
    float bitcrushBits;
    /// Ring modulator frequency, Hz, 0…1000 (0 = off), and its mix 0…1.
    float ringModHz;
    float ringModMix;
    /// Chorus and flanger amounts, 0…1.
    float chorus;
    float flanger;
    /// Echo: mix 0…1, delay 40…800 ms, feedback 0…0.8.
    float echoMix;
    float echoDelayMs;
    float echoFeedback;
    /// Reverb: mix 0…1, room size 0…1.
    float reverbMix;
    float reverbSize;
    /// Breath noise following the voice envelope, 0…1.
    float breathiness;
    /// Compressor amount 0…1 (threshold and ratio grow together).
    float compression;
    /// Output gain, dB, −12…12.
    float gainDb;
    /// Vibrato: rate 0…12 Hz, depth 0…1 semitone.
    float vibratoRateHz;
    float vibratoDepth;
    /// Slow random pitch drift, 0…1 (up to ±0.7 semitone): makes undoing the pitch shift harder.
    float jitter;
    /// Share of the processed signal, 0…1. Below 1 the real voice is audible in the mix.
    float wet;
} GGVoiceParams;

void GGVoiceParamsSetIdentity(GGVoiceParams *params);
/// True when the chain would not change the sound (callers then skip it entirely).
bool GGVoiceParamsIsIdentity(const GGVoiceParams *params);

typedef struct GGVoiceChain GGVoiceChain;

/// Allocates everything the chain needs for sample rates up to `maxSampleRate` (clamped to 8000…96000).
/// The parameters are copied and never change; build a new chain for new parameters.
GGVoiceChain * _Nullable GGVoiceChainCreate(const GGVoiceParams *params, uint32_t maxSampleRate);
void GGVoiceChainDestroy(GGVoiceChain * _Nullable chain);
/// Clears the delay lines and filter states (a new clip or call with the same parameters).
void GGVoiceChainReset(GGVoiceChain *chain);
/// Configures the chain for a sample rate ahead of time (off the realtime thread). Processing at another
/// rate reconfigures on the fly without allocating.
void GGVoiceChainPrepare(GGVoiceChain *chain, uint32_t sampleRate);

/// Realtime-safe. Interleaved samples, processed in place; several channels are mixed to mono for the
/// effects and the result is written to every channel. A sample rate above the chain's maximum is
/// processed with delay lengths capped to the allocated buffers.
void GGVoiceChainProcessFloat(GGVoiceChain *chain, float *samples, size_t frames, size_t channels, uint32_t sampleRate);
void GGVoiceChainProcessInt16(GGVoiceChain *chain, int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate);

/// The same two functions with the signature of `GGCallCaptureEffect` (GGCallAudio): `context` is the chain.
void GGVoiceChainCallProcess(void * _Nullable context, int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate);
void GGVoiceChainCallRelease(void * _Nullable context);

// MARK: - Playback equalizer

/// What a renderer plays. Service sounds (recording tone, silence keep-alive) have no equalizer at all.
typedef enum GGAudioEqualizerKind {
    GGAudioEqualizerKindAudio = 0,
    GGAudioEqualizerKindRoundVideo = 1,
    GGAudioEqualizerKindVideo = 2
} GGAudioEqualizerKind;

enum { GGAudioEqualizerBandCount = 5 };

/// Control side (any thread, never realtime): publishes the band gains (dB, −12…12) and which kinds
/// of media they apply to. Renderers pick the change up on their next block, without a click.
void GGAudioEqualizerSetParameters(const float * _Nonnull gainsDb, bool audio, bool roundVideo, bool video);
/// Cheap check for the renderers: whether this kind is equalized right now.
bool GGAudioEqualizerIsActiveForKind(GGAudioEqualizerKind kind);
/// The centre frequencies of the bands, Hz (for the menu).
float GGAudioEqualizerBandFrequency(int band);

typedef struct GGAudioEqualizer GGAudioEqualizer;

GGAudioEqualizer * _Nullable GGAudioEqualizerCreate(GGAudioEqualizerKind kind);
void GGAudioEqualizerDestroy(GGAudioEqualizer * _Nullable equalizer);
/// Realtime-safe; interleaved, in place, up to 8 channels.
void GGAudioEqualizerProcessInt16(GGAudioEqualizer *equalizer, int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate);
void GGAudioEqualizerProcessFloat(GGAudioEqualizer *equalizer, float *samples, size_t frames, size_t channels, uint32_t sampleRate);

/// Offline helper for the menu preview: applies the given gains (not the published ones) to mono samples.
void GGAudioEqualizerProcessOffline(const float * _Nonnull gainsDb, float *samples, size_t frames, uint32_t sampleRate);

#ifdef __cplusplus
}
#endif

#pragma clang assume_nonnull end

#endif
