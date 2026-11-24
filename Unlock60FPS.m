#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <math.h>

static const NSInteger kTargetFPS = 60;
static _Atomic uint32_t gRenderedFrames = 0;

static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL swizSel) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    if (!origMethod || !swizMethod) return;

    BOOL didAdd = class_addMethod(cls, origSel,
                                  method_getImplementation(swizMethod),
                                  method_getTypeEncoding(swizMethod));
    if (didAdd) {
        class_replaceMethod(cls, swizSel,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

static void SwizzleClassMethod(Class cls, SEL origSel, SEL swizSel) {
    if (!cls) return;
    Class metaCls = object_getClass((id)cls);
    SwizzleInstanceMethod(metaCls, origSel, swizSel);
}

@implementation CAMetalLayer (Unlock60FPS)

- (id<CAMetalDrawable>)u60_nextDrawable {
    id<CAMetalDrawable> drawable = [self u60_nextDrawable];
    if (drawable) {
        atomic_fetch_add_explicit(&gRenderedFrames, 1, memory_order_relaxed);
    }
    return drawable;
}

@end

typedef BOOL (*PresentRenderbufferIMP)(id, SEL, NSUInteger);
static PresentRenderbufferIMP orig_presentRenderbuffer = NULL;

static BOOL hooked_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    BOOL ok = orig_presentRenderbuffer ? orig_presentRenderbuffer(self, _cmd, target) : NO;
    if (ok) {
        atomic_fetch_add_explicit(&gRenderedFrames, 1, memory_order_relaxed);
    }
    return ok;
}

@implementation CADisplayLink (Unlock60FPS)

- (void)u60_setFrameInterval:(NSInteger)frameInterval {
    [self u60_setFrameInterval:1];
}

- (void)u60_setPreferredFramesPerSecond:(NSInteger)fps {
    [self u60_setPreferredFramesPerSecond:kTargetFPS];
}

- (void)u60_setPreferredFrameRateRange:(CAFrameRateRange)range API_AVAILABLE(ios(15.0)) {
    CAFrameRateRange forced = CAFrameRateRangeMake(kTargetFPS, kTargetFPS, kTargetFPS);
    [self u60_setPreferredFrameRateRange:forced];
}

+ (CADisplayLink *)u60_displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *link = [self u60_displayLinkWithTarget:target selector:sel];
    if (link) {
        if (@available(iOS 15.0, *)) {
            [link u60_setPreferredFrameRateRange:CAFrameRateRangeMake(kTargetFPS, kTargetFPS, kTargetFPS)];
        } else {
            [link u60_setPreferredFramesPerSecond:kTargetFPS];
        }
    }
    return link;
}

@end

@implementation MTKView (Unlock60FPS)

- (void)u60_setPreferredFramesPerSecond:(NSInteger)fps {
    [self u60_setPreferredFramesPerSecond:kTargetFPS];
}

@end

typedef void (*PresentAfterMinDurationIMP)(id, SEL, id<MTLDrawable>, CFTimeInterval);
static PresentAfterMinDurationIMP orig_presentAfterMinDuration = NULL;

static void hooked_presentAfterMinDuration(id self, SEL _cmd, id<MTLDrawable> drawable, CFTimeInterval duration) {
    if (orig_presentAfterMinDuration) {
        if (duration > 0.02) {
            duration = 1.0 / (double)kTargetFPS;
        }
        orig_presentAfterMinDuration(self, _cmd, drawable, duration);
    }
}

static UILabel *gFPSLabel = nil;
static dispatch_source_t gFPSTimer = nil;
static CFTimeInterval gLastSampleTime = 0;

static UIWindow *GetActiveKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *w in windowScene.windows) {
                if (w.isKeyWindow && !w.isHidden) return w;
            }
            if (windowScene.windows.firstObject) {
                return windowScene.windows.firstObject;
            }
        }
    }
    id<UIApplicationDelegate> delegate = [UIApplication sharedApplication].delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        return [delegate window];
    }
    return nil;
}

static void StartFPSOverlayIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gFPSLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 16, 86, 24)];
        gFPSLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
        gFPSLabel.textColor = [UIColor whiteColor];
        gFPSLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightBold];
        gFPSLabel.textAlignment = NSTextAlignmentCenter;
        gFPSLabel.layer.cornerRadius = 6.0;
        gFPSLabel.clipsToBounds = YES;
        gFPSLabel.userInteractionEnabled = NO;
        gFPSLabel.layer.zPosition = 9999;
        gFPSLabel.text = @"FPS: --";

        gLastSampleTime = CACurrentMediaTime();
        atomic_store_explicit(&gRenderedFrames, 0, memory_order_relaxed);

        gFPSTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gFPSTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                  (uint64_t)(0.5 * NSEC_PER_SEC),
                                  (uint64_t)(0.05 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(gFPSTimer, ^{
            CFTimeInterval now = CACurrentMediaTime();
            CFTimeInterval dt = now - gLastSampleTime;
            uint32_t frames = atomic_exchange_explicit(&gRenderedFrames, 0, memory_order_relaxed);
            gLastSampleTime = now;

            if (dt > 0.1 && dt < 3.0) {
                int fps = (int)llround((double)frames / dt);
                gFPSLabel.text = [NSString stringWithFormat:@"%d FPS", fps];
                if (fps >= 50) {
                    gFPSLabel.textColor = [UIColor colorWithRed:0.20 green:0.95 blue:0.45 alpha:1.0];
                } else if (fps >= 35) {
                    gFPSLabel.textColor = [UIColor colorWithRed:1.00 green:0.85 blue:0.20 alpha:1.0];
                } else {
                    gFPSLabel.textColor = [UIColor colorWithRed:1.00 green:0.35 blue:0.30 alpha:1.0];
                }
            }

            UIWindow *win = GetActiveKeyWindow();
            if (win) {
                if (gFPSLabel.superview != win) {
                    [win addSubview:gFPSLabel];
                }
                [win bringSubviewToFront:gFPSLabel];
                UIEdgeInsets insets = win.safeAreaInsets;
                CGFloat x = MAX(insets.left, 12.0) + 6.0;
                CGFloat y = MAX(insets.top, 12.0) + 4.0;
                gFPSLabel.frame = CGRectMake(x, y, 86.0, 24.0);
            }
        });
        dispatch_resume(gFPSTimer);
    });
}

__attribute__((constructor))
static void Unlock60FPSInit(void) {
    @autoreleasepool {
        SwizzleInstanceMethod([CAMetalLayer class],
                              @selector(nextDrawable),
                              @selector(u60_nextDrawable));

        Class eaglCls = NSClassFromString(@"EAGLContext");
        if (eaglCls) {
            SEL sel = NSSelectorFromString(@"presentRenderbuffer:");
            Method m = class_getInstanceMethod(eaglCls, sel);
            if (m) {
                orig_presentRenderbuffer = (PresentRenderbufferIMP)method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_presentRenderbuffer);
            }
        }

        SwizzleClassMethod([CADisplayLink class],
                           @selector(displayLinkWithTarget:selector:),
                           @selector(u60_displayLinkWithTarget:selector:));
        SwizzleInstanceMethod([CADisplayLink class],
                              @selector(setFrameInterval:),
                              @selector(u60_setFrameInterval:));
        SwizzleInstanceMethod([CADisplayLink class],
                              @selector(setPreferredFramesPerSecond:),
                              @selector(u60_setPreferredFramesPerSecond:));
        if (@available(iOS 15.0, *)) {
            SwizzleInstanceMethod([CADisplayLink class],
                                  @selector(setPreferredFrameRateRange:),
                                  @selector(u60_setPreferredFrameRateRange:));
        }

        SwizzleInstanceMethod([MTKView class],
                              @selector(setPreferredFramesPerSecond:),
                              @selector(u60_setPreferredFramesPerSecond:));

        Class mtlCmdBufCls = NSClassFromString(@"_MTLCommandBuffer");
        if (mtlCmdBufCls) {
            SEL sel = @selector(presentDrawable:afterMinimumDuration:);
            Method m = class_getInstanceMethod(mtlCmdBufCls, sel);
            if (m) {
                orig_presentAfterMinDuration = (PresentAfterMinDurationIMP)method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_presentAfterMinDuration);
            }
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            StartFPSOverlayIfNeeded();
        }];
    }
}
