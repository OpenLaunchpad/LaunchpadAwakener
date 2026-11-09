// The private Objective-C interfaces of system frameworks that the springboard and its hosts call
// directly. Each class is exported by its framework and the SDK has a stub to link against; the methods
// are declared exactly as the running system implements them, checked on macOS 26.6.2 and 27.2.
//
// Nothing here is checked again at run time: a declaration that stops matching a future macOS calls
// the method with the wrong signature. Calls into the Dock's own classes, which no framework exports,
// keep their run-time checks in LaunchpadAwakenerPayloadCore.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - IconFoundation

/// A colour IconServices tints icons with.
@interface IFColor : NSObject

/// A system colour, the way the Dock picks one for a named tint.
- (nullable instancetype)initWithSystemColor:(NSInteger)systemColor
                                  appearance:(NSInteger)appearance
                                    contrast:(NSInteger)contrast
                                    vibrancy:(NSInteger)vibrancy
    NS_SWIFT_NAME(init(systemColor:appearance:contrast:vibrancy:));

- (nullable instancetype)initWithCGColor:(CGColorRef)color NS_SWIFT_NAME(init(cgColor:));

@end

// MARK: - IconServices

/// What an icon is rendered for: its size, scale and style.
@interface ISImageDescriptor : NSObject <NSCopying>

@property (nonatomic) CGSize size;
@property (nonatomic) double scale;
@property (nonatomic) NSInteger appearance;
@property (nonatomic) NSInteger appearanceVariant;
@property (nonatomic) NSUInteger background;
@property (nonatomic, strong, nullable) IFColor *tintColor;

@end

/// A rendered icon image; the concrete class varies.
@protocol ISImage <NSObject>

@property (readonly, nullable) CGImageRef CGImage NS_SWIFT_NAME(cgImage);

@end

/// An icon. A class cluster: `+alloc` hands out an `ISIconFactory`, whose `-initWithURL:` returns the
/// concrete icon for the file.
@interface ISIcon : NSObject

- (nullable instancetype)initWithURL:(NSURL *)url NS_SWIFT_NAME(init(url:));

- (void)prepareImagesForImageDescriptors:(NSArray<ISImageDescriptor *> *)imageDescriptors
    NS_SWIFT_NAME(prepareImages(forImageDescriptors:));

- (nullable id<ISImage>)imageForImageDescriptor:(ISImageDescriptor *)imageDescriptor
    NS_SWIFT_NAME(image(forImageDescriptor:));

@end

// MARK: - SkyLight

/// The icon appearance the user chose in System Settings, as the window server holds it.
@interface SLSIconAppearanceConfiguration : NSObject

+ (nullable instancetype)fetchCurrentIconAppearanceConfiguration
    NS_SWIFT_NAME(fetchCurrentIconAppearanceConfiguration());

/// 0 automatic, 1 light, 2 dark; 3 automatic clear, 4 and 5 clear light and dark; 6 automatic tinted,
/// 7 and 8 tinted.
@property (readonly) uint32_t iconAppearanceTheme;
/// Non-zero is dark.
@property (readonly) uint32_t appearanceTheme;
/// 0 follows the accent colour, 1 the hardware one, 2…9 red to graphite, 10 `otherIconTintColor`.
@property (readonly) uint32_t iconTintColorName;
@property (readonly, nullable) CGColorRef otherIconTintColor;

@end

// MARK: - QuartzCore

/// A filter `CALayer.filters` accepts in the render server.
@interface CAFilter : NSObject

+ (nullable instancetype)filterWithType:(NSString *)type NS_SWIFT_NAME(init(type:));

@end

/// A render server context, identified across processes by `contextId`.
@interface CAContext : NSObject

@property (readonly) uint32_t contextId;

@end

/// Shows the layers of a context in another process.
@interface CALayerHost : CALayer

@property uint32_t contextId;

@end

NS_ASSUME_NONNULL_END
