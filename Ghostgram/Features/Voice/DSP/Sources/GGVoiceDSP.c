#include "GGVoiceDSP.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// MARK: - Common pieces

#define GG_PI 3.14159265358979f
#define GG_SINE_TABLE_SIZE 2048
#define GG_BLOCK_FRAMES 1024
#define GG_CONTROL_INTERVAL 32
#define GG_MAX_CHANNELS 8

typedef struct GGBiquad {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
    float z1;
    float z2;
} GGBiquad;

static inline float gg_biquad_run(GGBiquad *f, float x) {
    float y = f->b0 * x + f->z1;
    f->z1 = f->b1 * x - f->a1 * y + f->z2;
    f->z2 = f->b2 * x - f->a2 * y;
    return y;
}

static float gg_clamp_frequency(float frequency, float sampleRate) {
    float limit = sampleRate * 0.45f;
    if (frequency > limit) {
        return limit;
    }
    if (frequency < 10.0f) {
        return 10.0f;
    }
    return frequency;
}

static void gg_biquad_set(GGBiquad *f, float b0, float b1, float b2, float a0, float a1, float a2) {
    float inv = 1.0f / a0;
    f->b0 = b0 * inv;
    f->b1 = b1 * inv;
    f->b2 = b2 * inv;
    f->a1 = a1 * inv;
    f->a2 = a2 * inv;
}

static void gg_biquad_identity(GGBiquad *f) {
    f->b0 = 1.0f;
    f->b1 = 0.0f;
    f->b2 = 0.0f;
    f->a1 = 0.0f;
    f->a2 = 0.0f;
}

// Coefficient setters keep the state (z1, z2): a change of gain does not click.
static void gg_biquad_peak(GGBiquad *f, float sampleRate, float frequency, float q, float gainDb) {
    float A = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * GG_PI * gg_clamp_frequency(frequency, sampleRate) / sampleRate;
    float cosw = cosf(w0);
    float alpha = sinf(w0) / (2.0f * q);
    gg_biquad_set(f, 1.0f + alpha * A, -2.0f * cosw, 1.0f - alpha * A, 1.0f + alpha / A, -2.0f * cosw, 1.0f - alpha / A);
}

static void gg_biquad_low_shelf(GGBiquad *f, float sampleRate, float frequency, float gainDb) {
    float A = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * GG_PI * gg_clamp_frequency(frequency, sampleRate) / sampleRate;
    float cosw = cosf(w0);
    float alpha = sinf(w0) * 0.5f * 1.41421356f;
    float sqrtA2alpha = 2.0f * sqrtf(A) * alpha;
    gg_biquad_set(f,
        A * ((A + 1.0f) - (A - 1.0f) * cosw + sqrtA2alpha),
        2.0f * A * ((A - 1.0f) - (A + 1.0f) * cosw),
        A * ((A + 1.0f) - (A - 1.0f) * cosw - sqrtA2alpha),
        (A + 1.0f) + (A - 1.0f) * cosw + sqrtA2alpha,
        -2.0f * ((A - 1.0f) + (A + 1.0f) * cosw),
        (A + 1.0f) + (A - 1.0f) * cosw - sqrtA2alpha);
}

static void gg_biquad_high_shelf(GGBiquad *f, float sampleRate, float frequency, float gainDb) {
    float A = powf(10.0f, gainDb / 40.0f);
    float w0 = 2.0f * GG_PI * gg_clamp_frequency(frequency, sampleRate) / sampleRate;
    float cosw = cosf(w0);
    float alpha = sinf(w0) * 0.5f * 1.41421356f;
    float sqrtA2alpha = 2.0f * sqrtf(A) * alpha;
    gg_biquad_set(f,
        A * ((A + 1.0f) + (A - 1.0f) * cosw + sqrtA2alpha),
        -2.0f * A * ((A - 1.0f) + (A + 1.0f) * cosw),
        A * ((A + 1.0f) + (A - 1.0f) * cosw - sqrtA2alpha),
        (A + 1.0f) - (A - 1.0f) * cosw + sqrtA2alpha,
        2.0f * ((A - 1.0f) - (A + 1.0f) * cosw),
        (A + 1.0f) - (A - 1.0f) * cosw - sqrtA2alpha);
}

static void gg_biquad_high_pass(GGBiquad *f, float sampleRate, float frequency) {
    float w0 = 2.0f * GG_PI * gg_clamp_frequency(frequency, sampleRate) / sampleRate;
    float cosw = cosf(w0);
    float alpha = sinf(w0) / (2.0f * 0.7071f);
    gg_biquad_set(f, (1.0f + cosw) * 0.5f, -(1.0f + cosw), (1.0f + cosw) * 0.5f, 1.0f + alpha, -2.0f * cosw, 1.0f - alpha);
}

static void gg_biquad_low_pass(GGBiquad *f, float sampleRate, float frequency) {
    float w0 = 2.0f * GG_PI * gg_clamp_frequency(frequency, sampleRate) / sampleRate;
    float cosw = cosf(w0);
    float alpha = sinf(w0) / (2.0f * 0.7071f);
    gg_biquad_set(f, (1.0f - cosw) * 0.5f, 1.0f - cosw, (1.0f - cosw) * 0.5f, 1.0f + alpha, -2.0f * cosw, 1.0f - alpha);
}

static inline float gg_fast_tanh(float x) {
    if (x > 3.0f) {
        return 1.0f;
    }
    if (x < -3.0f) {
        return -1.0f;
    }
    float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

static inline float gg_soft_limit(float x) {
    float a = fabsf(x);
    if (a <= 0.8f) {
        return x;
    }
    float limited = 0.8f + 0.2f * gg_fast_tanh((a - 0.8f) / 0.2f);
    return x < 0.0f ? -limited : limited;
}

static inline int16_t gg_float_to_int16(float x) {
    float scaled = x * 32767.0f;
    if (scaled > 32767.0f) {
        return 32767;
    }
    if (scaled < -32768.0f) {
        return -32768;
    }
    return (int16_t)lrintf(scaled);
}

static uint32_t gg_next_power_of_two(uint32_t value) {
    uint32_t result = 1;
    while (result < value && result < (1u << 30)) {
        result <<= 1;
    }
    return result;
}

static float gg_clampf(float value, float minValue, float maxValue) {
    if (!(value == value)) {
        return minValue;
    }
    if (value < minValue) {
        return minValue;
    }
    if (value > maxValue) {
        return maxValue;
    }
    return value;
}

// MARK: - Voice parameters

void GGVoiceParamsSetIdentity(GGVoiceParams *params) {
    memset(params, 0, sizeof(GGVoiceParams));
    params->bitcrushBits = 16.0f;
    params->echoDelayMs = 250.0f;
    params->reverbSize = 0.5f;
    params->wet = 1.0f;
}

static GGVoiceParams gg_sanitized_params(const GGVoiceParams *source) {
    GGVoiceParams p = *source;
    p.pitchSemitones = gg_clampf(p.pitchSemitones, -12.0f, 12.0f);
    p.timbre = gg_clampf(p.timbre, -1.0f, 1.0f);
    p.bassDb = gg_clampf(p.bassDb, -12.0f, 12.0f);
    p.midDb = gg_clampf(p.midDb, -12.0f, 12.0f);
    p.trebleDb = gg_clampf(p.trebleDb, -12.0f, 12.0f);
    p.telephone = gg_clampf(p.telephone, 0.0f, 1.0f);
    p.distortion = gg_clampf(p.distortion, 0.0f, 1.0f);
    p.bitcrushBits = gg_clampf(p.bitcrushBits, 2.0f, 16.0f);
    p.ringModHz = gg_clampf(p.ringModHz, 0.0f, 1000.0f);
    p.ringModMix = gg_clampf(p.ringModMix, 0.0f, 1.0f);
    p.chorus = gg_clampf(p.chorus, 0.0f, 1.0f);
    p.flanger = gg_clampf(p.flanger, 0.0f, 1.0f);
    p.echoMix = gg_clampf(p.echoMix, 0.0f, 1.0f);
    p.echoDelayMs = gg_clampf(p.echoDelayMs, 40.0f, 800.0f);
    p.echoFeedback = gg_clampf(p.echoFeedback, 0.0f, 0.8f);
    p.reverbMix = gg_clampf(p.reverbMix, 0.0f, 1.0f);
    p.reverbSize = gg_clampf(p.reverbSize, 0.0f, 1.0f);
    p.breathiness = gg_clampf(p.breathiness, 0.0f, 1.0f);
    p.compression = gg_clampf(p.compression, 0.0f, 1.0f);
    p.gainDb = gg_clampf(p.gainDb, -12.0f, 12.0f);
    p.vibratoRateHz = gg_clampf(p.vibratoRateHz, 0.0f, 12.0f);
    p.vibratoDepth = gg_clampf(p.vibratoDepth, 0.0f, 1.0f);
    p.jitter = gg_clampf(p.jitter, 0.0f, 1.0f);
    p.wet = gg_clampf(p.wet, 0.0f, 1.0f);
    return p;
}

static bool gg_pitch_active(const GGVoiceParams *p) {
    if (fabsf(p->pitchSemitones) > 0.01f) {
        return true;
    }
    if (p->vibratoDepth > 0.001f && p->vibratoRateHz > 0.01f) {
        return true;
    }
    return p->jitter > 0.001f;
}

bool GGVoiceParamsIsIdentity(const GGVoiceParams *source) {
    GGVoiceParams p = gg_sanitized_params(source);
    if (p.wet < 0.001f) {
        return fabsf(p.gainDb) < 0.01f;
    }
    if (gg_pitch_active(&p)) {
        return false;
    }
    if (fabsf(p.timbre) > 0.01f || fabsf(p.bassDb) > 0.01f || fabsf(p.midDb) > 0.01f || fabsf(p.trebleDb) > 0.01f) {
        return false;
    }
    if (p.telephone > 0.001f || p.distortion > 0.001f || p.bitcrushBits < 15.99f) {
        return false;
    }
    if (p.ringModHz > 0.01f && p.ringModMix > 0.001f) {
        return false;
    }
    if (p.chorus > 0.001f || p.flanger > 0.001f || p.echoMix > 0.001f || p.reverbMix > 0.001f) {
        return false;
    }
    if (p.breathiness > 0.001f || p.compression > 0.001f || fabsf(p.gainDb) > 0.01f) {
        return false;
    }
    return true;
}

// MARK: - Voice chain

struct GGVoiceChain {
    GGVoiceParams params;
    uint32_t maxSampleRate;
    uint32_t sampleRate;
    float sineTable[GG_SINE_TABLE_SIZE + 1];
    float scratch[GG_BLOCK_FRAMES];
    uint32_t rng;

    // Pitch: two crossfaded taps on one delay line.
    bool pitchActive;
    float *pitchBuffer;
    uint32_t pitchMask;
    uint32_t pitchWrite;
    float pitchWindow;
    float pitchPhase;
    float pitchRatio;
    uint32_t controlCounter;
    float vibratoPhase;
    float vibratoIncrement;
    float jitterValue;
    float jitterTarget;
    uint32_t jitterCounter;
    uint32_t jitterPeriod;

    // Filters.
    bool timbreActive;
    GGBiquad timbreLow;
    GGBiquad timbreHigh;
    bool eqActive;
    GGBiquad eqLow;
    GGBiquad eqMid;
    GGBiquad eqHigh;
    bool phoneActive;
    GGBiquad phoneHigh;
    GGBiquad phoneLow;

    // Distortion and bitcrusher.
    float distortionDrive;
    float distortionNorm;
    float bitcrushLevels;

    // Ring modulator.
    bool ringActive;
    float ringPhase;
    float ringIncrement;

    // Chorus.
    float *chorusBuffer;
    uint32_t chorusMask;
    uint32_t chorusWrite;
    float chorusPhase;
    float chorusIncrement;
    float chorusBase;
    float chorusDepth;

    // Flanger.
    float *flangerBuffer;
    uint32_t flangerMask;
    uint32_t flangerWrite;
    float flangerPhase;
    float flangerIncrement;
    float flangerBase;
    float flangerDepth;

    // Echo.
    float *echoBuffer;
    uint32_t echoMask;
    uint32_t echoWrite;
    uint32_t echoDelay;

    // Reverb (4 damped combs + 2 allpasses).
    float *combBuffers[4];
    uint32_t combCapacity[4];
    uint32_t combLength[4];
    uint32_t combIndex[4];
    float combStore[4];
    float combFeedback;
    float combDamp;
    float *allpassBuffers[2];
    uint32_t allpassCapacity[2];
    uint32_t allpassLength[2];
    uint32_t allpassIndex[2];

    // Breath.
    float breathEnvelope;
    float breathRelease;
    float breathHighPass;
    float breathPreviousNoise;
    float breathCoefficient;

    // Compressor.
    bool compressorActive;
    float compressorEnvelope;
    float compressorGain;
    float compressorTargetGain;
    float compressorThresholdDb;
    float compressorRatio;
    float compressorAttack;
    float compressorRelease;
    float compressorMakeupDb;
    uint32_t compressorCounter;

    float gainLinear;
};

static const float gg_comb_tuning[4] = { 1116.0f, 1188.0f, 1277.0f, 1356.0f };
static const float gg_allpass_tuning[2] = { 556.0f, 441.0f };

static inline float gg_chain_sine(const GGVoiceChain *chain, float phase) {
    float position = phase * (float)GG_SINE_TABLE_SIZE;
    int index = (int)position;
    if (index < 0) {
        index = 0;
    }
    if (index >= GG_SINE_TABLE_SIZE) {
        index = GG_SINE_TABLE_SIZE - 1;
    }
    float frac = position - (float)index;
    return chain->sineTable[index] + frac * (chain->sineTable[index + 1] - chain->sineTable[index]);
}

static inline float gg_wrap_phase(float phase) {
    if (phase >= 1.0f) {
        phase -= floorf(phase);
    } else if (phase < 0.0f) {
        phase -= floorf(phase);
    }
    return phase;
}

static inline uint32_t gg_next_random(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static inline float gg_random_bipolar(uint32_t *state) {
    return (float)(gg_next_random(state) >> 8) * (1.0f / 8388608.0f) - 1.0f;
}

static inline float gg_delay_read(const float *buffer, uint32_t mask, uint32_t writeIndex, float delay) {
    float position = (float)writeIndex - 1.0f - delay;
    float size = (float)(mask + 1);
    while (position < 0.0f) {
        position += size;
    }
    uint32_t i0 = ((uint32_t)position) & mask;
    float frac = position - floorf(position);
    uint32_t i1 = (i0 + 1) & mask;
    return buffer[i0] + frac * (buffer[i1] - buffer[i0]);
}

static float *gg_alloc_buffer(uint32_t count) {
    return (float *)calloc(count, sizeof(float));
}

GGVoiceChain *GGVoiceChainCreate(const GGVoiceParams *params, uint32_t maxSampleRate) {
    GGVoiceChain *chain = (GGVoiceChain *)calloc(1, sizeof(GGVoiceChain));
    if (chain == NULL) {
        return NULL;
    }
    chain->params = gg_sanitized_params(params);
    if (maxSampleRate < 8000) {
        maxSampleRate = 8000;
    }
    if (maxSampleRate > 96000) {
        maxSampleRate = 96000;
    }
    chain->maxSampleRate = maxSampleRate;
    chain->rng = 0x9E3779B9u ^ (uint32_t)(uintptr_t)chain;
    if (chain->rng == 0) {
        chain->rng = 1;
    }
    for (int i = 0; i <= GG_SINE_TABLE_SIZE; i++) {
        chain->sineTable[i] = sinf(2.0f * GG_PI * (float)i / (float)GG_SINE_TABLE_SIZE);
    }

    const GGVoiceParams *p = &chain->params;
    float maxRate = (float)maxSampleRate;
    bool failed = false;

    chain->pitchActive = gg_pitch_active(p);
    if (chain->pitchActive) {
        uint32_t size = gg_next_power_of_two((uint32_t)(maxRate * 0.1f));
        chain->pitchBuffer = gg_alloc_buffer(size);
        chain->pitchMask = size - 1;
        failed = failed || chain->pitchBuffer == NULL;
    }
    if (p->chorus > 0.001f) {
        uint32_t size = gg_next_power_of_two((uint32_t)(maxRate * 0.04f));
        chain->chorusBuffer = gg_alloc_buffer(size);
        chain->chorusMask = size - 1;
        failed = failed || chain->chorusBuffer == NULL;
    }
    if (p->flanger > 0.001f) {
        uint32_t size = gg_next_power_of_two((uint32_t)(maxRate * 0.012f));
        chain->flangerBuffer = gg_alloc_buffer(size);
        chain->flangerMask = size - 1;
        failed = failed || chain->flangerBuffer == NULL;
    }
    if (p->echoMix > 0.001f) {
        uint32_t size = gg_next_power_of_two((uint32_t)(maxRate * 0.82f));
        chain->echoBuffer = gg_alloc_buffer(size);
        chain->echoMask = size - 1;
        failed = failed || chain->echoBuffer == NULL;
    }
    if (p->reverbMix > 0.001f) {
        for (int i = 0; i < 4; i++) {
            uint32_t capacity = (uint32_t)(gg_comb_tuning[i] * maxRate / 44100.0f * 1.35f) + 2;
            chain->combBuffers[i] = gg_alloc_buffer(capacity);
            chain->combCapacity[i] = capacity;
            failed = failed || chain->combBuffers[i] == NULL;
        }
        for (int i = 0; i < 2; i++) {
            uint32_t capacity = (uint32_t)(gg_allpass_tuning[i] * maxRate / 44100.0f) + 2;
            chain->allpassBuffers[i] = gg_alloc_buffer(capacity);
            chain->allpassCapacity[i] = capacity;
            failed = failed || chain->allpassBuffers[i] == NULL;
        }
    }
    if (failed) {
        GGVoiceChainDestroy(chain);
        return NULL;
    }
    return chain;
}

void GGVoiceChainDestroy(GGVoiceChain *chain) {
    if (chain == NULL) {
        return;
    }
    free(chain->pitchBuffer);
    free(chain->chorusBuffer);
    free(chain->flangerBuffer);
    free(chain->echoBuffer);
    for (int i = 0; i < 4; i++) {
        free(chain->combBuffers[i]);
    }
    for (int i = 0; i < 2; i++) {
        free(chain->allpassBuffers[i]);
    }
    free(chain);
}

static void gg_clear_biquad(GGBiquad *f) {
    f->z1 = 0.0f;
    f->z2 = 0.0f;
}

void GGVoiceChainReset(GGVoiceChain *chain) {
    if (chain->pitchBuffer != NULL) {
        memset(chain->pitchBuffer, 0, sizeof(float) * (chain->pitchMask + 1));
    }
    if (chain->chorusBuffer != NULL) {
        memset(chain->chorusBuffer, 0, sizeof(float) * (chain->chorusMask + 1));
    }
    if (chain->flangerBuffer != NULL) {
        memset(chain->flangerBuffer, 0, sizeof(float) * (chain->flangerMask + 1));
    }
    if (chain->echoBuffer != NULL) {
        memset(chain->echoBuffer, 0, sizeof(float) * (chain->echoMask + 1));
    }
    for (int i = 0; i < 4; i++) {
        if (chain->combBuffers[i] != NULL) {
            memset(chain->combBuffers[i], 0, sizeof(float) * chain->combCapacity[i]);
        }
        chain->combIndex[i] = 0;
        chain->combStore[i] = 0.0f;
    }
    for (int i = 0; i < 2; i++) {
        if (chain->allpassBuffers[i] != NULL) {
            memset(chain->allpassBuffers[i], 0, sizeof(float) * chain->allpassCapacity[i]);
        }
        chain->allpassIndex[i] = 0;
    }
    gg_clear_biquad(&chain->timbreLow);
    gg_clear_biquad(&chain->timbreHigh);
    gg_clear_biquad(&chain->eqLow);
    gg_clear_biquad(&chain->eqMid);
    gg_clear_biquad(&chain->eqHigh);
    gg_clear_biquad(&chain->phoneHigh);
    gg_clear_biquad(&chain->phoneLow);
    chain->pitchWrite = 0;
    chain->pitchPhase = 0.0f;
    chain->controlCounter = 0;
    chain->vibratoPhase = 0.0f;
    chain->jitterValue = 0.0f;
    chain->jitterTarget = 0.0f;
    chain->jitterCounter = 0;
    chain->ringPhase = 0.0f;
    chain->chorusWrite = 0;
    chain->chorusPhase = 0.0f;
    chain->flangerWrite = 0;
    chain->flangerPhase = 0.0f;
    chain->echoWrite = 0;
    chain->breathEnvelope = 0.0f;
    chain->breathHighPass = 0.0f;
    chain->breathPreviousNoise = 0.0f;
    chain->compressorEnvelope = 0.0f;
    chain->compressorGain = 1.0f;
    chain->compressorTargetGain = 1.0f;
    chain->compressorCounter = 0;
}

/// Everything that depends on the sample rate. Math only, no allocation: callable on the realtime thread.
static void gg_chain_configure(GGVoiceChain *chain, uint32_t sampleRate) {
    const GGVoiceParams *p = &chain->params;
    float rate = (float)sampleRate;
    chain->sampleRate = sampleRate;

    if (chain->pitchActive) {
        float window = rate * 0.045f;
        float limit = (float)chain->pitchMask - 4.0f;
        if (window > limit) {
            window = limit;
        }
        if (window < 64.0f) {
            window = 64.0f;
        }
        chain->pitchWindow = window;
        chain->pitchRatio = powf(2.0f, p->pitchSemitones / 12.0f);
        chain->vibratoIncrement = p->vibratoRateHz * (float)GG_CONTROL_INTERVAL / rate;
        chain->jitterPeriod = (uint32_t)(rate * 0.15f / (float)GG_CONTROL_INTERVAL) + 1;
    }

    chain->timbreActive = fabsf(p->timbre) > 0.01f;
    if (chain->timbreActive) {
        gg_biquad_low_shelf(&chain->timbreLow, rate, 300.0f, -6.0f * p->timbre);
        gg_biquad_high_shelf(&chain->timbreHigh, rate, 2500.0f, 9.0f * p->timbre);
    }
    chain->eqActive = fabsf(p->bassDb) > 0.01f || fabsf(p->midDb) > 0.01f || fabsf(p->trebleDb) > 0.01f;
    if (chain->eqActive) {
        gg_biquad_low_shelf(&chain->eqLow, rate, 200.0f, p->bassDb);
        gg_biquad_peak(&chain->eqMid, rate, 1000.0f, 0.8f, p->midDb);
        gg_biquad_high_shelf(&chain->eqHigh, rate, 4000.0f, p->trebleDb);
    }
    chain->phoneActive = p->telephone > 0.001f;
    if (chain->phoneActive) {
        gg_biquad_high_pass(&chain->phoneHigh, rate, 300.0f);
        gg_biquad_low_pass(&chain->phoneLow, rate, 3400.0f);
    }

    chain->distortionDrive = 1.0f + 14.0f * p->distortion;
    chain->distortionNorm = 1.0f / gg_fast_tanh(chain->distortionDrive);
    chain->bitcrushLevels = powf(2.0f, p->bitcrushBits - 1.0f);

    chain->ringActive = p->ringModHz > 0.01f && p->ringModMix > 0.001f;
    chain->ringIncrement = p->ringModHz / rate;

    if (chain->chorusBuffer != NULL) {
        chain->chorusIncrement = 0.8f / rate;
        chain->chorusBase = rate * 0.02f;
        chain->chorusDepth = rate * 0.005f;
        float limit = (float)chain->chorusMask - 2.0f;
        if (chain->chorusBase + chain->chorusDepth > limit) {
            chain->chorusBase = limit * 0.7f;
            chain->chorusDepth = limit * 0.25f;
        }
    }
    if (chain->flangerBuffer != NULL) {
        chain->flangerIncrement = 0.25f / rate;
        chain->flangerBase = rate * 0.0035f;
        chain->flangerDepth = rate * 0.0025f;
        float limit = (float)chain->flangerMask - 2.0f;
        if (chain->flangerBase + chain->flangerDepth > limit) {
            chain->flangerBase = limit * 0.55f;
            chain->flangerDepth = limit * 0.4f;
        }
    }
    if (chain->echoBuffer != NULL) {
        uint32_t delay = (uint32_t)(p->echoDelayMs * 0.001f * rate);
        if (delay > chain->echoMask) {
            delay = chain->echoMask;
        }
        if (delay < 1) {
            delay = 1;
        }
        chain->echoDelay = delay;
    }
    if (chain->combBuffers[0] != NULL) {
        float sizeScale = 0.75f + 0.5f * p->reverbSize;
        for (int i = 0; i < 4; i++) {
            uint32_t length = (uint32_t)(gg_comb_tuning[i] * rate / 44100.0f * sizeScale);
            if (length >= chain->combCapacity[i]) {
                length = chain->combCapacity[i] - 1;
            }
            if (length < 1) {
                length = 1;
            }
            chain->combLength[i] = length;
            chain->combIndex[i] = 0;
        }
        for (int i = 0; i < 2; i++) {
            uint32_t length = (uint32_t)(gg_allpass_tuning[i] * rate / 44100.0f);
            if (length >= chain->allpassCapacity[i]) {
                length = chain->allpassCapacity[i] - 1;
            }
            if (length < 1) {
                length = 1;
            }
            chain->allpassLength[i] = length;
            chain->allpassIndex[i] = 0;
        }
        chain->combFeedback = 0.70f + 0.25f * p->reverbSize;
        chain->combDamp = 0.3f;
    }

    chain->breathRelease = expf(-1.0f / (0.03f * rate));
    chain->breathCoefficient = expf(-2.0f * GG_PI * 2000.0f / rate);

    chain->compressorActive = p->compression > 0.001f;
    if (chain->compressorActive) {
        chain->compressorThresholdDb = -8.0f - 22.0f * p->compression;
        chain->compressorRatio = 1.0f + 5.0f * p->compression;
        chain->compressorAttack = 1.0f - expf(-1.0f / (0.005f * rate));
        chain->compressorRelease = 1.0f - expf(-1.0f / (0.08f * rate));
        chain->compressorMakeupDb = -chain->compressorThresholdDb * (1.0f - 1.0f / chain->compressorRatio) * 0.5f;
    }
    chain->gainLinear = powf(10.0f, p->gainDb / 20.0f);

    GGVoiceChainReset(chain);
}

static void gg_chain_update_pitch_control(GGVoiceChain *chain) {
    const GGVoiceParams *p = &chain->params;
    float semitones = p->pitchSemitones;
    if (p->vibratoDepth > 0.001f && p->vibratoRateHz > 0.01f) {
        chain->vibratoPhase = gg_wrap_phase(chain->vibratoPhase + chain->vibratoIncrement);
        semitones += p->vibratoDepth * gg_chain_sine(chain, chain->vibratoPhase);
    }
    if (p->jitter > 0.001f) {
        chain->jitterCounter += 1;
        if (chain->jitterCounter >= chain->jitterPeriod) {
            chain->jitterCounter = 0;
            chain->jitterTarget = gg_random_bipolar(&chain->rng) * 0.7f * p->jitter;
        }
        chain->jitterValue += (chain->jitterTarget - chain->jitterValue) * 0.08f;
        semitones += chain->jitterValue;
    }
    chain->pitchRatio = exp2f(semitones / 12.0f);
}

static inline float gg_chain_pitch(GGVoiceChain *chain, float x) {
    float *buffer = chain->pitchBuffer;
    uint32_t mask = chain->pitchMask;
    buffer[chain->pitchWrite] = x;
    chain->pitchWrite = (chain->pitchWrite + 1) & mask;

    float window = chain->pitchWindow;
    float phase = chain->pitchPhase + (1.0f - chain->pitchRatio) / window;
    phase = gg_wrap_phase(phase);
    chain->pitchPhase = phase;
    float phase2 = phase + 0.5f;
    if (phase2 >= 1.0f) {
        phase2 -= 1.0f;
    }
    // sin²(πp) + sin²(π(p + ½)) = 1: the taps fade out exactly where their delay wraps.
    float s1 = gg_chain_sine(chain, phase * 0.5f);
    float s2 = gg_chain_sine(chain, phase2 * 0.5f);
    float g1 = s1 * s1;
    float g2 = s2 * s2;
    float y1 = gg_delay_read(buffer, mask, chain->pitchWrite, phase * window);
    float y2 = gg_delay_read(buffer, mask, chain->pitchWrite, phase2 * window);
    return y1 * g1 + y2 * g2;
}

static void gg_chain_process_mono(GGVoiceChain *chain, float *samples, size_t frames) {
    const GGVoiceParams *p = &chain->params;
    for (size_t i = 0; i < frames; i++) {
        float dry = samples[i];
        float x = dry;

        if (chain->pitchActive) {
            if (chain->controlCounter == 0) {
                gg_chain_update_pitch_control(chain);
            }
            chain->controlCounter = (chain->controlCounter + 1) % GG_CONTROL_INTERVAL;
            x = gg_chain_pitch(chain, x);
        }
        if (chain->timbreActive) {
            x = gg_biquad_run(&chain->timbreHigh, gg_biquad_run(&chain->timbreLow, x));
        }
        if (chain->eqActive) {
            x = gg_biquad_run(&chain->eqHigh, gg_biquad_run(&chain->eqMid, gg_biquad_run(&chain->eqLow, x)));
        }
        if (chain->phoneActive) {
            float band = gg_biquad_run(&chain->phoneLow, gg_biquad_run(&chain->phoneHigh, x));
            x = x + (band * 1.4f - x) * p->telephone;
        }
        if (p->distortion > 0.001f) {
            float saturated = gg_fast_tanh(x * chain->distortionDrive) * chain->distortionNorm;
            x = x + (saturated - x) * p->distortion;
        }
        if (p->bitcrushBits < 15.99f) {
            x = floorf(x * chain->bitcrushLevels + 0.5f) / chain->bitcrushLevels;
        }
        if (chain->ringActive) {
            chain->ringPhase = gg_wrap_phase(chain->ringPhase + chain->ringIncrement);
            float modulated = x * gg_chain_sine(chain, chain->ringPhase);
            x = x + (modulated - x) * p->ringModMix;
        }
        if (chain->chorusBuffer != NULL) {
            chain->chorusBuffer[chain->chorusWrite] = x;
            chain->chorusWrite = (chain->chorusWrite + 1) & chain->chorusMask;
            chain->chorusPhase = gg_wrap_phase(chain->chorusPhase + chain->chorusIncrement);
            float delay = chain->chorusBase + chain->chorusDepth * gg_chain_sine(chain, chain->chorusPhase);
            float delayed = gg_delay_read(chain->chorusBuffer, chain->chorusMask, chain->chorusWrite, delay);
            x = x * (1.0f - 0.4f * p->chorus) + delayed * 0.6f * p->chorus;
        }
        if (chain->flangerBuffer != NULL) {
            chain->flangerPhase = gg_wrap_phase(chain->flangerPhase + chain->flangerIncrement);
            float delay = chain->flangerBase + chain->flangerDepth * gg_chain_sine(chain, chain->flangerPhase);
            float delayed = gg_delay_read(chain->flangerBuffer, chain->flangerMask, chain->flangerWrite, delay);
            chain->flangerBuffer[chain->flangerWrite] = x + delayed * 0.55f * p->flanger;
            chain->flangerWrite = (chain->flangerWrite + 1) & chain->flangerMask;
            x = (x + delayed * p->flanger) / (1.0f + 0.5f * p->flanger);
        }
        if (chain->echoBuffer != NULL) {
            uint32_t readIndex = (chain->echoWrite - chain->echoDelay) & chain->echoMask;
            float delayed = chain->echoBuffer[readIndex];
            chain->echoBuffer[chain->echoWrite] = x + delayed * p->echoFeedback;
            chain->echoWrite = (chain->echoWrite + 1) & chain->echoMask;
            x = x + delayed * p->echoMix;
        }
        if (chain->combBuffers[0] != NULL) {
            float input = x * 0.3f;
            float sum = 0.0f;
            for (int c = 0; c < 4; c++) {
                float *buffer = chain->combBuffers[c];
                uint32_t index = chain->combIndex[c];
                float output = buffer[index];
                chain->combStore[c] = output * (1.0f - chain->combDamp) + chain->combStore[c] * chain->combDamp;
                buffer[index] = input + chain->combStore[c] * chain->combFeedback;
                index += 1;
                if (index >= chain->combLength[c]) {
                    index = 0;
                }
                chain->combIndex[c] = index;
                sum += output;
            }
            float reverb = sum * 0.25f;
            for (int a = 0; a < 2; a++) {
                float *buffer = chain->allpassBuffers[a];
                uint32_t index = chain->allpassIndex[a];
                float buffered = buffer[index];
                float output = buffered - reverb;
                buffer[index] = reverb + buffered * 0.5f;
                index += 1;
                if (index >= chain->allpassLength[a]) {
                    index = 0;
                }
                chain->allpassIndex[a] = index;
                reverb = output;
            }
            x = x + reverb * p->reverbMix * 1.5f;
        }
        if (p->breathiness > 0.001f) {
            float level = fabsf(x);
            chain->breathEnvelope = level > chain->breathEnvelope ? level : chain->breathEnvelope * chain->breathRelease;
            float noise = gg_random_bipolar(&chain->rng);
            chain->breathHighPass = chain->breathCoefficient * (chain->breathHighPass + noise - chain->breathPreviousNoise);
            chain->breathPreviousNoise = noise;
            x += chain->breathHighPass * chain->breathEnvelope * p->breathiness * 0.6f;
        }
        if (chain->compressorActive) {
            float level = fabsf(x);
            float coefficient = level > chain->compressorEnvelope ? chain->compressorAttack : chain->compressorRelease;
            chain->compressorEnvelope += (level - chain->compressorEnvelope) * coefficient;
            if (chain->compressorCounter == 0) {
                float envelopeDb = 20.0f * log10f(chain->compressorEnvelope + 1e-6f);
                float over = envelopeDb - chain->compressorThresholdDb;
                float gainDb = chain->compressorMakeupDb;
                if (over > 0.0f) {
                    gainDb -= over * (1.0f - 1.0f / chain->compressorRatio);
                }
                chain->compressorTargetGain = powf(10.0f, gainDb / 20.0f);
            }
            chain->compressorCounter = (chain->compressorCounter + 1) % 16;
            chain->compressorGain += (chain->compressorTargetGain - chain->compressorGain) * 0.01f;
            x *= chain->compressorGain;
        }
        x *= chain->gainLinear;
        if (p->wet < 0.999f) {
            x = dry + (x - dry) * p->wet;
        }
        samples[i] = gg_soft_limit(x);
    }
}

static void gg_chain_prepare(GGVoiceChain *chain, uint32_t sampleRate) {
    if (sampleRate == 0) {
        sampleRate = 48000;
    }
    if (chain->sampleRate != sampleRate) {
        gg_chain_configure(chain, sampleRate);
    }
}

void GGVoiceChainPrepare(GGVoiceChain *chain, uint32_t sampleRate) {
    gg_chain_prepare(chain, sampleRate);
}

void GGVoiceChainProcessFloat(GGVoiceChain *chain, float *samples, size_t frames, size_t channels, uint32_t sampleRate) {
    if (frames == 0 || channels == 0) {
        return;
    }
    gg_chain_prepare(chain, sampleRate);
    if (channels == 1) {
        gg_chain_process_mono(chain, samples, frames);
        return;
    }
    size_t offset = 0;
    while (offset < frames) {
        size_t count = frames - offset;
        if (count > GG_BLOCK_FRAMES) {
            count = GG_BLOCK_FRAMES;
        }
        float scale = 1.0f / (float)channels;
        for (size_t i = 0; i < count; i++) {
            const float *frame = samples + (offset + i) * channels;
            float sum = 0.0f;
            for (size_t c = 0; c < channels; c++) {
                sum += frame[c];
            }
            chain->scratch[i] = sum * scale;
        }
        gg_chain_process_mono(chain, chain->scratch, count);
        for (size_t i = 0; i < count; i++) {
            float *frame = samples + (offset + i) * channels;
            for (size_t c = 0; c < channels; c++) {
                frame[c] = chain->scratch[i];
            }
        }
        offset += count;
    }
}

void GGVoiceChainProcessInt16(GGVoiceChain *chain, int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate) {
    if (frames == 0 || channels == 0) {
        return;
    }
    gg_chain_prepare(chain, sampleRate);
    size_t offset = 0;
    const float scale = 1.0f / 32768.0f;
    while (offset < frames) {
        size_t count = frames - offset;
        if (count > GG_BLOCK_FRAMES) {
            count = GG_BLOCK_FRAMES;
        }
        float channelScale = scale / (float)channels;
        for (size_t i = 0; i < count; i++) {
            const int16_t *frame = samples + (offset + i) * channels;
            float sum = 0.0f;
            for (size_t c = 0; c < channels; c++) {
                sum += (float)frame[c];
            }
            chain->scratch[i] = sum * channelScale;
        }
        gg_chain_process_mono(chain, chain->scratch, count);
        for (size_t i = 0; i < count; i++) {
            int16_t value = gg_float_to_int16(chain->scratch[i]);
            int16_t *frame = samples + (offset + i) * channels;
            for (size_t c = 0; c < channels; c++) {
                frame[c] = value;
            }
        }
        offset += count;
    }
}

void GGVoiceChainCallProcess(void *context, int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate) {
    if (context == NULL) {
        return;
    }
    GGVoiceChainProcessInt16((GGVoiceChain *)context, samples, frames, channels, sampleRate);
}

void GGVoiceChainCallRelease(void *context) {
    GGVoiceChainDestroy((GGVoiceChain *)context);
}

// MARK: - Playback equalizer

static const float gg_eq_frequencies[GGAudioEqualizerBandCount] = { 60.0f, 230.0f, 910.0f, 3600.0f, 14000.0f };

// Seqlock: the writer (control side, serialized by the mutex) makes the counter odd while it writes.
static _Atomic uint32_t gg_eq_sequence = 0;
static _Atomic float gg_eq_gains[GGAudioEqualizerBandCount];
static _Atomic bool gg_eq_kinds[3];
static pthread_mutex_t gg_eq_writer_lock = PTHREAD_MUTEX_INITIALIZER;

float GGAudioEqualizerBandFrequency(int band) {
    if (band < 0 || band >= GGAudioEqualizerBandCount) {
        return 0.0f;
    }
    return gg_eq_frequencies[band];
}

void GGAudioEqualizerSetParameters(const float *gainsDb, bool audio, bool roundVideo, bool video) {
    pthread_mutex_lock(&gg_eq_writer_lock);
    atomic_fetch_add_explicit(&gg_eq_sequence, 1, memory_order_acq_rel);
    for (int i = 0; i < GGAudioEqualizerBandCount; i++) {
        atomic_store_explicit(&gg_eq_gains[i], gg_clampf(gainsDb[i], -12.0f, 12.0f), memory_order_relaxed);
    }
    atomic_store_explicit(&gg_eq_kinds[GGAudioEqualizerKindAudio], audio, memory_order_relaxed);
    atomic_store_explicit(&gg_eq_kinds[GGAudioEqualizerKindRoundVideo], roundVideo, memory_order_relaxed);
    atomic_store_explicit(&gg_eq_kinds[GGAudioEqualizerKindVideo], video, memory_order_relaxed);
    atomic_fetch_add_explicit(&gg_eq_sequence, 1, memory_order_release);
    pthread_mutex_unlock(&gg_eq_writer_lock);
}

/// Reads a consistent copy; false if the writer kept it busy (the caller keeps what it had).
static bool gg_eq_snapshot(float *gains, bool *kinds, uint32_t *sequence) {
    for (int attempt = 0; attempt < 8; attempt++) {
        uint32_t before = atomic_load_explicit(&gg_eq_sequence, memory_order_acquire);
        if ((before & 1u) != 0) {
            continue;
        }
        for (int i = 0; i < GGAudioEqualizerBandCount; i++) {
            gains[i] = atomic_load_explicit(&gg_eq_gains[i], memory_order_relaxed);
        }
        for (int i = 0; i < 3; i++) {
            kinds[i] = atomic_load_explicit(&gg_eq_kinds[i], memory_order_relaxed);
        }
        atomic_thread_fence(memory_order_acquire);
        uint32_t after = atomic_load_explicit(&gg_eq_sequence, memory_order_relaxed);
        if (before == after) {
            *sequence = before;
            return true;
        }
    }
    return false;
}

static bool gg_eq_has_gain(const float *gains) {
    for (int i = 0; i < GGAudioEqualizerBandCount; i++) {
        if (fabsf(gains[i]) > 0.05f) {
            return true;
        }
    }
    return false;
}

bool GGAudioEqualizerIsActiveForKind(GGAudioEqualizerKind kind) {
    if ((int)kind < 0 || (int)kind > 2) {
        return false;
    }
    if (!atomic_load_explicit(&gg_eq_kinds[kind], memory_order_relaxed)) {
        return false;
    }
    for (int i = 0; i < GGAudioEqualizerBandCount; i++) {
        if (fabsf(atomic_load_explicit(&gg_eq_gains[i], memory_order_relaxed)) > 0.05f) {
            return true;
        }
    }
    return false;
}

struct GGAudioEqualizer {
    GGAudioEqualizerKind kind;
    uint32_t sequence;
    bool hasSnapshot;
    uint32_t sampleRate;
    bool active;
    float gains[GGAudioEqualizerBandCount];
    float preamp;
    GGBiquad coefficients[GGAudioEqualizerBandCount];
    float state[GG_MAX_CHANNELS][GGAudioEqualizerBandCount][2];
};

GGAudioEqualizer *GGAudioEqualizerCreate(GGAudioEqualizerKind kind) {
    GGAudioEqualizer *equalizer = (GGAudioEqualizer *)calloc(1, sizeof(GGAudioEqualizer));
    if (equalizer == NULL) {
        return NULL;
    }
    equalizer->kind = kind;
    equalizer->preamp = 1.0f;
    for (int i = 0; i < GGAudioEqualizerBandCount; i++) {
        gg_biquad_identity(&equalizer->coefficients[i]);
    }
    return equalizer;
}

void GGAudioEqualizerDestroy(GGAudioEqualizer *equalizer) {
    free(equalizer);
}

static void gg_eq_compute(const float *gains, float sampleRate, GGBiquad *coefficients, float *preamp) {
    float maxBoost = 0.0f;
    for (int i = 0; i < GGAudioEqualizerBandCount; i++) {
        float gain = gains[i];
        if (gain > maxBoost) {
            maxBoost = gain;
        }
        if (fabsf(gain) <= 0.05f) {
            gg_biquad_identity(&coefficients[i]);
        } else if (i == 0) {
            gg_biquad_low_shelf(&coefficients[i], sampleRate, gg_eq_frequencies[i], gain);
        } else if (i == GGAudioEqualizerBandCount - 1) {
            gg_biquad_high_shelf(&coefficients[i], sampleRate, gg_eq_frequencies[i], gain);
        } else {
            gg_biquad_peak(&coefficients[i], sampleRate, gg_eq_frequencies[i], 1.0f, gain);
        }
    }
    // Half of the strongest boost as headroom: boosted bands do not clip the rest.
    *preamp = powf(10.0f, -0.5f * maxBoost / 20.0f);
}

/// Picks up a new parameter set or sample rate. The filter states are kept: no click on a change.
static void gg_eq_refresh(GGAudioEqualizer *equalizer, uint32_t sampleRate) {
    uint32_t current = atomic_load_explicit(&gg_eq_sequence, memory_order_acquire);
    if (equalizer->hasSnapshot && current == equalizer->sequence && sampleRate == equalizer->sampleRate) {
        return;
    }
    float gains[GGAudioEqualizerBandCount];
    bool kinds[3];
    uint32_t sequence = 0;
    if (!gg_eq_snapshot(gains, kinds, &sequence)) {
        return;
    }
    bool wasActive = equalizer->active;
    equalizer->hasSnapshot = true;
    equalizer->sequence = sequence;
    equalizer->sampleRate = sampleRate;
    equalizer->active = kinds[equalizer->kind] && gg_eq_has_gain(gains);
    memcpy(equalizer->gains, gains, sizeof(gains));
    if (equalizer->active) {
        gg_eq_compute(gains, (float)sampleRate, equalizer->coefficients, &equalizer->preamp);
        if (!wasActive) {
            memset(equalizer->state, 0, sizeof(equalizer->state));
        }
    }
}

static inline float gg_eq_run(GGAudioEqualizer *equalizer, size_t channel, float x) {
    x *= equalizer->preamp;
    for (int b = 0; b < GGAudioEqualizerBandCount; b++) {
        const GGBiquad *f = &equalizer->coefficients[b];
        float *z = equalizer->state[channel][b];
        float y = f->b0 * x + z[0];
        z[0] = f->b1 * x - f->a1 * y + z[1];
        z[1] = f->b2 * x - f->a2 * y;
        x = y;
    }
    return x;
}

void GGAudioEqualizerProcessInt16(GGAudioEqualizer *equalizer, int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate) {
    if (frames == 0 || channels == 0 || sampleRate == 0) {
        return;
    }
    gg_eq_refresh(equalizer, sampleRate);
    if (!equalizer->active) {
        return;
    }
    size_t processedChannels = channels > GG_MAX_CHANNELS ? GG_MAX_CHANNELS : channels;
    const float scale = 1.0f / 32768.0f;
    for (size_t i = 0; i < frames; i++) {
        int16_t *frame = samples + i * channels;
        for (size_t c = 0; c < processedChannels; c++) {
            frame[c] = gg_float_to_int16(gg_eq_run(equalizer, c, (float)frame[c] * scale));
        }
    }
}

void GGAudioEqualizerProcessFloat(GGAudioEqualizer *equalizer, float *samples, size_t frames, size_t channels, uint32_t sampleRate) {
    if (frames == 0 || channels == 0 || sampleRate == 0) {
        return;
    }
    gg_eq_refresh(equalizer, sampleRate);
    if (!equalizer->active) {
        return;
    }
    size_t processedChannels = channels > GG_MAX_CHANNELS ? GG_MAX_CHANNELS : channels;
    for (size_t i = 0; i < frames; i++) {
        float *frame = samples + i * channels;
        for (size_t c = 0; c < processedChannels; c++) {
            frame[c] = gg_soft_limit(gg_eq_run(equalizer, c, frame[c]));
        }
    }
}

void GGAudioEqualizerProcessOffline(const float *gainsDb, float *samples, size_t frames, uint32_t sampleRate) {
    if (frames == 0 || sampleRate == 0) {
        return;
    }
    float gains[GGAudioEqualizerBandCount];
    for (int i = 0; i < GGAudioEqualizerBandCount; i++) {
        gains[i] = gg_clampf(gainsDb[i], -12.0f, 12.0f);
    }
    if (!gg_eq_has_gain(gains)) {
        return;
    }
    GGAudioEqualizer equalizer;
    memset(&equalizer, 0, sizeof(equalizer));
    equalizer.active = true;
    gg_eq_compute(gains, (float)sampleRate, equalizer.coefficients, &equalizer.preamp);
    for (size_t i = 0; i < frames; i++) {
        samples[i] = gg_soft_limit(gg_eq_run(&equalizer, 0, samples[i]));
    }
}
