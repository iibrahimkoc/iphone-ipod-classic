// iPodKiosk: keeps the iPod app in front.
//  - The app is launched whenever the home screen would show (after unlock, respring, app exit).
//  - The home button returns to the app instead of the home screen; double/triple/long presses are ignored.
//  - Control Center, Notification Center and other system gestures are disabled while unlocked.
//  - Waking the screen skips the lock screen (only possible when the phone has no passcode).
//  - Escape hatch: 5 quick home presses unlocks everything until the iPod app is reopened or the phone locks.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

static NSString *const kAppID = @"com.ibrahimkoc.clickwheel";
static const NSUInteger kEscapePresses = 5;
static const NSTimeInterval kEscapeWindow = 3.0;

static BOOL escaped = NO;
static NSMutableArray<NSDate *> *presses;
static id gestureManager;

// Calls a no-argument method returning `ret`.
#define SEND(ret) ((ret (*)(id, SEL))objc_msgSend)

static BOOL isLocked(void) {
    id manager = SEND(id)(NSClassFromString(@"SBLockScreenManager"), @selector(sharedInstance));
    return manager && SEND(BOOL)(manager, @selector(isUILocked));
}

static BOOL kioskActive(void) {
    return !escaped && !isLocked();
}

static NSString *frontAppID(void) {
    id app = SEND(id)(UIApplication.sharedApplication, NSSelectorFromString(@"_accessibilityFrontMostApplication"));
    return app ? SEND(NSString *)(app, NSSelectorFromString(@"bundleIdentifier")) : nil;
}

static void launchApp(void) {
    if (!kioskActive() || [frontAppID() isEqualToString:kAppID]) return;
    ((BOOL (*)(id, SEL, NSString *, BOOL))objc_msgSend)(UIApplication.sharedApplication,
        NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:"), kAppID, NO);
}

static void launchAppSoon(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        launchApp();
    });
}

static void setEscaped(BOOL value) {
    if (escaped == value) return;
    escaped = value;
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    // Gesture enablement is cached; ask SpringBoard to re-evaluate it.
    if ([gestureManager respondsToSelector:NSSelectorFromString(@"_evaluateEnablement")]) {
        SEND(void)(gestureManager, NSSelectorFromString(@"_evaluateEnablement"));
    }
}

// Swaps in `block` (taking self, then the method's arguments) and returns the original IMP.
static IMP hook(NSString *className, NSString *selector, id block) {
    Method method = class_getInstanceMethod(NSClassFromString(className), NSSelectorFromString(selector));
    if (!method) {
        NSLog(@"[iPodKiosk] missing -[%@ %@]", className, selector);
        return NULL;
    }
    return method_setImplementation(method, imp_implementationWithBlock(block));
}

// Hooks for "do nothing while the kiosk is active" methods.
static void swallow(NSString *className, NSString *selector) {
    __block IMP original = hook(className, selector, ^(id self) {
        if (kioskActive()) return;
        ((void (*)(id, SEL))original)(self, NSSelectorFromString(selector));
    });
}

__attribute__((constructor)) static void init(void) {
    presses = [NSMutableArray array];

    // MARK: Home button

    __block IMP singlePressUp;
    __block id buttonActions;
    __block IMP buttonDown = hook(@"SBHomeHardwareButtonActions", @"performInitialButtonDownActions", ^(id self) {
        buttonActions = self;
        NSDate *now = [NSDate date];
        [presses addObject:now];
        while (presses.count && [now timeIntervalSinceDate:presses.firstObject] > kEscapeWindow) [presses removeObjectAtIndex:0];
        if (presses.count >= kEscapePresses && !escaped) {
            [presses removeAllObjects];
            // Wait for the press sequence to finish so it isn't read as a double/triple press afterwards.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                setEscaped(YES);
                if (singlePressUp) ((void (*)(id, SEL))singlePressUp)(buttonActions, @selector(performSinglePressUpActions));
            });
        }
        ((void (*)(id, SEL))buttonDown)(self, @selector(performInitialButtonDownActions));
    });

    singlePressUp = hook(@"SBHomeHardwareButtonActions", @"performSinglePressUpActions", ^(id self) {
        if (kioskActive()) {
            launchApp();
            return;
        }
        ((void (*)(id, SEL))singlePressUp)(self, @selector(performSinglePressUpActions));
    });

    __block IMP singlePressUpWithSource = hook(@"SBHomeHardwareButtonActions", @"performSinglePressUpActionsWithSourceType:", ^(id self, long long source) {
        if (kioskActive()) {
            launchApp();
            return;
        }
        ((void (*)(id, SEL, long long))singlePressUpWithSource)(self, @selector(performSinglePressUpActionsWithSourceType:), source);
    });

    swallow(@"SBHomeHardwareButtonActions", @"performDoublePressDownActions");  // app switcher
    swallow(@"SBHomeHardwareButtonActions", @"performDoubleTapUpActions");      // reachability
    swallow(@"SBHomeHardwareButtonActions", @"performTriplePressUpActions");    // accessibility shortcut
    swallow(@"SBHomeHardwareButtonActions", @"performLongPressActions");        // Siri

    // MARK: System gestures (Control Center, Notification Center, ...)

    __block IMP gestureAllowed = hook(@"SBSystemGestureManager", @"isGestureWithTypeAllowed:", ^BOOL(id self, unsigned long long type) {
        gestureManager = self;
        if (kioskActive()) return NO;
        return ((BOOL (*)(id, SEL, unsigned long long))gestureAllowed)(self, @selector(isGestureWithTypeAllowed:), type);
    });

    __block IMP controlCenterGesture = hook(@"SBControlCenterController", @"_shouldAllowControlCenterGesture", ^BOOL(id self) {
        if (kioskActive()) return NO;
        return ((BOOL (*)(id, SEL))controlCenterGesture)(self, @selector(_shouldAllowControlCenterGesture));
    });

    // MARK: Keeping the app in front

    __block IMP frontDisplayDidChange = hook(@"SpringBoard", @"frontDisplayDidChange:", ^(id self, id display) {
        ((void (*)(id, SEL, id))frontDisplayDidChange)(self, @selector(frontDisplayDidChange:), display);
        NSString *bundleID = [display respondsToSelector:@selector(bundleIdentifier)] ? [display bundleIdentifier] : nil;
        if ([bundleID isEqualToString:kAppID]) {
            setEscaped(NO);
        } else if (!display) {
            launchAppSoon(0.3);
        }
    });

    __block IMP didDismiss = hook(@"SBLockScreenManager", @"lockScreenViewControllerDidDismiss", ^(id self) {
        ((void (*)(id, SEL))didDismiss)(self, @selector(lockScreenViewControllerDidDismiss));
        launchAppSoon(0.4);
    });

    __block IMP setUILocked = hook(@"SBLockScreenManager", @"_setUILocked:", ^(id self, BOOL locked) {
        ((void (*)(id, SEL, BOOL))setUILocked)(self, @selector(_setUILocked:), locked);
        if (locked) setEscaped(NO);
    });

    // MARK: Skipping the lock screen

    // SpringBoard posts this whenever the screen turns off (state 1) or on (state 0).
    int token;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t blanked = 0;
        notify_get_state(t, &blanked);
        if (blanked || escaped || !isLocked()) return;
        id manager = SEND(id)(NSClassFromString(@"SBLockScreenManager"), @selector(sharedInstance));
        SEL unlock = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
        if ([manager respondsToSelector:unlock]) {
            ((void (*)(id, SEL, int, id))objc_msgSend)(manager, unlock, 0, nil);
        }
    });

    // After a respring the phone is usually unlocked and nothing triggers a launch.
    launchAppSoon(4.0);
}
