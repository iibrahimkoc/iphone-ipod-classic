// iPodKiosk: keeps the iPod app in front.
//  - The app is launched whenever the home screen would show (after unlock, respring, app exit).
//  - The home button returns to the app instead of the home screen; double/triple/long presses are ignored.
//  - Control Center, Notification Center and other system gestures are disabled while unlocked.
//  - Waking the screen skips the lock screen (only possible when the phone has no passcode).
//  - The "no SIM card" alert and iOS's own low battery alert are suppressed (the app shows its own).
//  - The app can turn the screen off (battery quarantine) by posting com.ibrahimkoc.ipod.lock.
//  - The Mac's play/pause, next and previous arrive as a ".media" file in the music folder and are
//    sent like the lock screen's buttons, which wakes the app even when iOS has suspended it.
//  - Escape hatch: 5 quick home presses unlocks everything until the iPod app is reopened or the phone locks.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>

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

// Makes the lock screen (cover sheet) and the wallpaper invisible, so waking shows black and then
// the app; the lock screen is still there and dismissed right away. Restored while escaped so the
// normal lock and home screens work.
static void setCoverSheetHidden(BOOL hidden) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSString *name = NSStringFromClass(window.class);
        if ([name containsString:@"CoverSheet"] || [name containsString:@"Wallpaper"]) window.alpha = hidden ? 0 : 1;
    }
}

static void setEscaped(BOOL value) {
    if (escaped == value) return;
    escaped = value;
    setCoverSheetHidden(!value);
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

// Alerts an iPod doesn't need: iOS's low battery alert (the app has its own warning) and SIM
// alerts, which the phone service sends as user notifications whenever the cellular radio starts.
static BOOL isSuppressedAlert(id item) {
    if ([NSStringFromClass([item class]) isEqualToString:@"SBLowPowerAlertItem"]) return YES;
    for (NSString *key in @[@"alertHeader", @"alertMessage", @"title", @"message"]) {
        SEL selector = NSSelectorFromString(key);
        if (![item respondsToSelector:selector]) continue;
        id text = SEND(id)(item, selector);
        if ([text isKindOfClass:NSString.class] && [text containsString:@"SIM"]) return YES;
    }
    return NO;
}

// MARK: Media keys from the Mac

static NSString *const kMusicFolder = @"/var/mobile/Media/iPodMuzik";
static dispatch_source_t mediaSource;

// The Mac writes "toggle", "next" or "prev" to .media; MediaRemote delivers it to the now-playing
// app (the iPod app), resuming it first if it was suspended while paused.
static void watchMediaCommands(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    Boolean (*send)(uint32_t, CFDictionaryRef) = lib ? dlsym(lib, "MRMediaRemoteSendCommand") : NULL;
    if (!send) return;
    int folder = open(kMusicFolder.fileSystemRepresentation, O_EVTONLY);
    if (folder < 0) return;
    mediaSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, folder, DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    dispatch_source_set_event_handler(mediaSource, ^{
        NSString *path = [kMusicFolder stringByAppendingPathComponent:@".media"];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!text) return;
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        // MRMediaRemoteCommand: 2 toggle play/pause, 4 next track, 5 previous track.
        NSDictionary *commands = @{ @"toggle": @2, @"next": @4, @"prev": @5 };
        NSNumber *command = commands[[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        if (command) send(command.unsignedIntValue, NULL);
    });
    dispatch_source_set_cancel_handler(mediaSource, ^{ close(folder); });
    dispatch_resume(mediaSource);
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
        BOOL wasLocked = !escaped && isLocked();
        ((void (*)(id, SEL))buttonDown)(self, @selector(performInitialButtonDownActions));
        // Waking with the home button: unlock on the press itself, like a side-button wake, instead
        // of letting the release run iOS's unlock animation (which briefly shows the status bar).
        if (wasLocked && singlePressUp) {
            ((void (*)(id, SEL))singlePressUp)(self, @selector(performSinglePressUpActions));
        }
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

    // MARK: Alerts

    __block IMP activateAlert = hook(@"SBAlertItemsController", @"activateAlertItem:", ^(id self, id item) {
        if (isSuppressedAlert(item)) return;
        ((void (*)(id, SEL, id))activateAlert)(self, @selector(activateAlertItem:), item);
    });

    __block IMP activateAlertAnimated = hook(@"SBAlertItemsController", @"activateAlertItem:animated:", ^(id self, id item, BOOL animated) {
        if (isSuppressedAlert(item)) return;
        ((void (*)(id, SEL, id, BOOL))activateAlertAnimated)(self, @selector(activateAlertItem:animated:), item, animated);
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
        if (blanked) {
            if (!escaped) setCoverSheetHidden(YES);
            return;
        }
        if (escaped || !isLocked()) return;
        // A direct unlock request is ignored here, so act as if the home button had been pressed,
        // which is what the lock screen asks for ("press home to open").
        dispatch_async(dispatch_get_main_queue(), ^{
            id button = SEND(id)(UIApplication.sharedApplication, NSSelectorFromString(@"homeHardwareButton"));
            id actions = button ? SEND(id)(button, NSSelectorFromString(@"buttonActions")) : nil;
            if (actions && singlePressUp) {
                ((void (*)(id, SEL))singlePressUp)(actions, @selector(performSinglePressUpActions));
            }
        });
    });

    // The app asks for the screen to be turned off while in battery quarantine.
    int lockToken;
    notify_register_dispatch("com.ibrahimkoc.ipod.lock", &lockToken, dispatch_get_main_queue(), ^(int t) {
        SEL lock = NSSelectorFromString(@"_simulateLockButtonPress");
        if ([UIApplication.sharedApplication respondsToSelector:lock]) SEND(void)(UIApplication.sharedApplication, lock);
    });

    watchMediaCommands();

    // After a respring the phone is usually unlocked and nothing triggers a launch.
    launchAppSoon(4.0);
}
