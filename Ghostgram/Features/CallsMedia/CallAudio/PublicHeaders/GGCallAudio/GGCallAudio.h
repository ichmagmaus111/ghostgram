#ifndef GGCallAudio_h
#define GGCallAudio_h

#import <Foundation/Foundation.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Per-device state of the call audio effects. One core belongs to one call audio device
/// (`SharedCallAudioDevice`); nothing here is process-global.
///
/// Threading: the realtime functions below are called by the device module for every captured and
/// played block, serialized by the module's own lock. They never allocate, lock, block or touch the
/// file system. Everything that allocates (clips, ring buffers, effects) happens on the control side
/// (`GGCallAudioEffects`), and retired objects are freed there once no realtime callback can still
/// see them.
typedef struct GGCallAudioCore GGCallAudioCore;

/// A voice effect applied to the captured microphone audio before it is sent (the call voice changer).
///
/// - `process` runs on the realtime capture thread for every block (usually 10 ms), in place, on
///   interleaved Int16 samples. It must not allocate, lock or block.
/// - `release` (optional) is called off the realtime thread once the core no longer uses the effect.
///
/// The microphone is processed first, then the soundboard clip is mixed in, so clips are never
/// altered by the effect. A silenced microphone (silent mute) skips the effect.
typedef struct GGCallCaptureEffect {
    void * _Nullable context;
    void (* _Nonnull process)(void * _Nullable context, int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate);
    void (* _Nullable release)(void * _Nullable context);
} GGCallCaptureEffect;

#ifdef __cplusplus
extern "C" {
#endif

void GGCallAudioCoreRetain(GGCallAudioCore *core);
void GGCallAudioCoreRelease(GGCallAudioCore *core);

/// Realtime. Applies silent mute, the voice effect and the soundboard clip to a captured block and feeds
/// the recording tap. Returns `samples` when nothing had to change, otherwise the core's own buffer with
/// the processed block (valid until the next call). `frames` = samples per channel.
const int16_t *GGCallAudioCoreProcessCapture(GGCallAudioCore *core, const int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate);

/// Realtime. The block the device is about to play (all remote audio mixed): feeds the recording tap.
void GGCallAudioCoreTapPlayout(GGCallAudioCore *core, const int16_t *samples, size_t frames, size_t channels, uint32_t sampleRate);

#ifdef __cplusplus
}
#endif

/// Audio collected for a recording since the previous drain: the remote side mixed with the microphone
/// (as sent, after the effects), mono Int16.
@interface GGCallAudioRecordingChunk : NSObject

@property (nonatomic, strong, readonly) NSData *samples;
@property (nonatomic, readonly) int32_t sampleRate;

@end

/// Control side of one call audio device's effects. Thread-safe; nothing here waits for the audio thread.
@interface GGCallAudioEffects : NSObject

- (instancetype)init;

/// The realtime core, for the device module. Owned by this object; retain it to keep it longer.
@property (nonatomic, readonly) GGCallAudioCore *core;

/// Silent mute: the captured audio is replaced with silence while the call itself stays unmuted, so the
/// other side sees no "microphone off" mark. Belongs to this device only.
@property (nonatomic) bool captureSilenced;

/// Mixes a clip into the outgoing audio, replacing the clip that is playing. `samples` = mono Int16 at
/// `sampleRate`; `volume` 0…1; `duckMicrophone` lowers the microphone to a quarter while the clip plays.
- (void)playClip:(NSData *)samples sampleRate:(int32_t)sampleRate volume:(float)volume duckMicrophone:(bool)duckMicrophone NS_SWIFT_NAME(playClip(_:sampleRate:volume:duckMicrophone:));
- (void)stopClip NS_SWIFT_NAME(stopClip());
/// True from `playClip` until the clip has been played to its end or stopped.
@property (nonatomic, readonly) bool isClipPlaying;

/// Starts collecting the call's audio for a recording. The ring buffers are allocated here (≈ 11 s of
/// audio each), never on the audio thread; drain at least every few seconds.
- (void)startRecordingIncludingMicrophone:(bool)includeMicrophone NS_SWIFT_NAME(startRecording(includingMicrophone:));
/// Takes everything collected since the previous drain. nil when nothing new arrived.
- (GGCallAudioRecordingChunk * _Nullable)drainRecording NS_SWIFT_NAME(drainRecording());
- (void)stopRecording NS_SWIFT_NAME(stopRecording());
@property (nonatomic, readonly) bool isRecording;
/// Blocks dropped because the recording was not drained in time (diagnostics).
@property (nonatomic, readonly) int64_t droppedRecordingBlocks;

/// Installs the voice effect for the captured audio (a copy of the struct is kept). NULL removes it.
/// The previous effect's `release` runs off the realtime thread once it is no longer in use.
- (void)setCaptureEffect:(GGCallCaptureEffect const * _Nullable)effect NS_SWIFT_NAME(setCaptureEffect(_:));

/// Defaults for a new call on a reused device: no silence, no clip, no recording, no voice effect.
- (void)reset NS_SWIFT_NAME(reset());

@end

NS_ASSUME_NONNULL_END

#endif
