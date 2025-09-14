//
//  LPAKDockInjection.m
//  DockInjection
//
//  Created by JH on 2025/9/11.
//

#import "LPAKDockInjection.h"
#include <objc/runtime.h>

@import LaunchpadAwakenerShim;
@import LaunchpadAwakenerServer;

@implementation LPAKDockInjection

+ (void)load {
    Class LPSpringboardClass = NSClassFromString(@"LPSpringboard");
    if (LPSpringboardClass) {
//        if (SpringboardClass && !class_conformsToProtocol(SpringboardClass, @protocol(LPAKSpringboard))) {
//            class_addProtocol(SpringboardClass, @protocol(LPAKSpringboard));
//        }
//        id<LPAKSpringboard> springboard = (__bridge id<LPAKSpringboard>)((void *)0xb79bf5200);
        NSObject *springboard = [[LPSpringboardClass alloc] performSelector:NSSelectorFromString(@"initWithEnvironment:") withObject:nil];
        NSLog(@"LPAKDockInjection running.");
        dispatch_async(dispatch_get_main_queue(), ^{
            [[LaunchpadAwakenerServer mainServer] runWithSpringboard:springboard];
        });
    }
}

@end
