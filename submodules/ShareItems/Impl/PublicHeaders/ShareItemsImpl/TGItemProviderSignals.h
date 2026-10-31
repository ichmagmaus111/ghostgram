#import <Foundation/Foundation.h>

@class MTSignal;

@interface TGItemProviderSignals : NSObject

+ (NSArray<MTSignal *> *)itemSignalsForInputItems:(NSArray *)inputItems;
+ (NSData *)audioWaveform:(NSURL *)url;
// GHOST: Ghostgram's outgoing photo settings. 0 (default) = upstream: photo files are scaled to 1280 px and compressed here. Otherwise they are decoded to this long side and passed on as `image`, for ShareItems to scale, mark and compress (GGOutgoingImageHooks).
+ (void)setGGPhotoMaxPixelSize:(CGFloat)size NS_SWIFT_NAME(setGGPhotoMaxPixelSize(_:));

@end
