#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#ifdef __cplusplus
extern "C" {
#endif

UIFont *TGSystemFontOfSize(CGFloat size);
UIFont *TGBoldSystemFontOfSize(CGFloat size);
UIFont *TGLightSystemFontOfSize(CGFloat size);
UIFont *TGUltralightSystemFontOfSize(CGFloat size);
UIFont *TGMediumSystemFontOfSize(CGFloat size);
UIFont *TGSemiboldSystemFontOfSize(CGFloat size);
UIFont *TGItalicSystemFontOfSize(CGFloat size);
UIFont *TGFixedSystemFontOfSize(CGFloat size);

CTFontRef TGCoreTextSystemFontOfSize(CGFloat size);
CTFontRef TGCoreTextMediumFontOfSize(CGFloat size);
CTFontRef TGCoreTextBoldFontOfSize(CGFloat size);
CTFontRef TGCoreTextLightFontOfSize(CGFloat size);
CTFontRef TGCoreTextFixedFontOfSize(CGFloat size);
CTFontRef TGCoreTextItalicFontOfSize(CGFloat size);

// GHOST: custom font family for the legacy screens. Set once at launch by Ghostgram; the block gets
// the size, a weight (0 regular, 1 light, 2 medium, 3 semibold, 4 bold) and italic, and returns the
// replacement or nil for the system font.
typedef UIFont *(^TGFontSubstitutionBlock)(CGFloat size, NSInteger weight, bool italic);
void TGFontSetSubstitution(TGFontSubstitutionBlock block);
    
#ifdef __cplusplus
}
#endif

@interface TGFont : NSObject

+ (UIFont *)systemFontOfSize:(CGFloat)size;
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size;

+ (UIFont *)roundedFontOfSize:(CGFloat)size;

@end
