// AppKit's private methods the text input helper calls directly, apart from
// LaunchpadAwakenerPrivateInterfaces so that importing that one never brings AppKit in. Declared exactly as
// macOS 26.6.2 and 27.2 implement them; nothing is checked again at run time.

#import <AppKit/AppKit.h>
#import "LaunchpadAwakenerPrivateInterfaces.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSDockTile (LaunchpadAwakenerPrivate)

/// The view the tile's mini view window shows.
@property (nonatomic, strong, nullable) NSView *miniView;

/// Until this is said, the mini view window cannot become key. 27.2's Dock no longer says it for an
/// application.
- (void)_setMiniViewShown:(BOOL)miniViewShown;

- (void)_setMiniViewWindowLevel:(NSInteger)miniViewWindowLevel;

@end

@interface NSWindow (LaunchpadAwakenerPrivate)

/// The context a `CALayerHost` in another process shows the window through.
@property (weak, readonly, nullable) CAContext *_contextForLayerHosting;

@end

NS_ASSUME_NONNULL_END
