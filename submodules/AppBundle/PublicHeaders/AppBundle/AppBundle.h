#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NSBundle * _Nonnull getAppBundle(void);

// GHOST: icon packs (GGInterface). An immutable «asset name → image» table published by the
// icon pack resolver; `UIImage(bundleImageName:)` answers from it before the asset catalog.
// GHOST: no pack — one atomic load per lookup; with a pack — a retain under an unfair lock. A replaced
// table is freed when its last reader is done (GHOST). `nil` (the default) = Telegram's assets.
void GGAppBundleSetImageOverrides(NSDictionary<NSString *, UIImage *> * _Nullable overrides);

@interface UIImage (AppBundle)

- (instancetype _Nullable)initWithBundleImageName:(NSString * _Nonnull)bundleImageName;

@end
