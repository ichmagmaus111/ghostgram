#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Processes one captured call frame on the capture queue. Returns a +1 retained buffer of the same
/// width, height and pixel format as the input, or NULL to keep the frame. In Swift the result is
/// `Unmanaged<CVPixelBuffer>?`: return `Unmanaged.passRetained(buffer)`.
typedef CVPixelBufferRef _Nullable (^GGCallFrameProcessorBlock)(CVPixelBufferRef pixelBuffer, BOOL isFrontCamera, int rotation);

/// The one hook tgcalls knows about: the camera capturer hands every frame to the processor that
/// Ghostgram installs (call masks). Depends on Foundation and CoreVideo only, so TgVoipWebrtc can
/// link it without seeing Swift or the camera modules.
@interface GGCallFrameBridge : NSObject

/// nil removes the processor.
+ (void)setProcessor:(GGCallFrameProcessorBlock _Nullable)processor;

/// One lock-protected load; the capturer asks it before doing anything else.
+ (BOOL)hasProcessor;

/// Runs the processor. A result that does not match the input's size or format is dropped (it
/// would reach the encoder with planes it was not set up for).
+ (CVPixelBufferRef _Nullable)copyProcessedPixelBuffer:(CVPixelBufferRef)pixelBuffer isFrontCamera:(BOOL)isFrontCamera rotation:(int)rotation CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
