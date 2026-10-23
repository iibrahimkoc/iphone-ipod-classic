#import "Torch.h"
#include <dlfcn.h>
#include <unistd.h>

// How the LEDs are driven comes from TrollLEDs (github.com/PoomSmart/TrollLEDs, MIT): CMCapture's
// device vendor hands out the camera device and its flashlight stream, and on dual-LED phones the
// stream takes TorchLevel (0–100) and TorchColor {WarmLEDPercentile}. On iOS 15 only the vendor's
// instance methods are there.

@interface BWFigCaptureStream : NSObject
- (int)setProperty:(CFStringRef)property value:(id)value;
@end

@interface BWFigCaptureDevice : NSObject
@end

@interface BWFigCaptureDeviceVendor : NSObject
+ (instancetype)sharedCaptureDeviceVendor;
- (int)registerClientWithPID:(pid_t)pid clientDescription:(NSString *)description clientPriority:(int)priority
    canStealFromClientsWithSamePriority:(BOOL)canSteal deviceSharingWithOtherClientsAllowed:(BOOL)sharing
    deviceAvailabilityChangedHandler:(id)handler;
- (BWFigCaptureDevice *)copyDeviceForClient:(int)client informClientWhenDeviceAvailableAgain:(BOOL)inform error:(int *)error;
- (BWFigCaptureStream *)copyStreamForFlashlightWithPosition:(int)position deviceType:(int)deviceType
    forDevice:(BWFigCaptureDevice *)device;
- (void)takeBackDevice:(BWFigCaptureDevice *)device forClient:(int)client informClientWhenDeviceAvailableAgain:(BOOL)inform;
@end

@implementation Torch {
    BWFigCaptureDeviceVendor *_vendor;
    BWFigCaptureDevice *_device;
    BWFigCaptureStream *_stream;
    int _client;
}

- (BOOL)open {
    if (_stream) return YES;
    dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW);
    Class vendorClass = NSClassFromString(@"BWFigCaptureDeviceVendor");
    if (![vendorClass respondsToSelector:@selector(sharedCaptureDeviceVendor)]) return NO;
    _vendor = [vendorClass sharedCaptureDeviceVendor];
    SEL registerClient = @selector(registerClientWithPID:clientDescription:clientPriority:canStealFromClientsWithSamePriority:deviceSharingWithOtherClientsAllowed:deviceAvailabilityChangedHandler:);
    if (![_vendor respondsToSelector:registerClient] ||
        ![_vendor respondsToSelector:@selector(copyDeviceForClient:informClientWhenDeviceAvailableAgain:error:)] ||
        ![_vendor respondsToSelector:@selector(copyStreamForFlashlightWithPosition:deviceType:forDevice:)]) return NO;

    _client = [_vendor registerClientWithPID:getpid() clientDescription:@"iPod Fener" clientPriority:1
                canStealFromClientsWithSamePriority:NO deviceSharingWithOtherClientsAllowed:YES
                deviceAvailabilityChangedHandler:nil];
    if (_client == 0) return NO;
    int error = 0;
    _device = [_vendor copyDeviceForClient:_client informClientWhenDeviceAvailableAgain:NO error:&error];
    // Position 1 is the back, device type 2 the wide camera, which carries the flash.
    _stream = _device ? [_vendor copyStreamForFlashlightWithPosition:1 deviceType:2 forDevice:_device] : nil;
    if (!_stream) [self stop];
    return _stream != nil;
}

- (BOOL)setLevel:(int)level warm:(int)warm {
    if (![self open]) return NO;
    [_stream setProperty:CFSTR("TorchColor") value:@{@"WarmLEDPercentile": @(MIN(MAX(warm, 0), 100))}];
    return [_stream setProperty:CFSTR("TorchLevel") value:@(MIN(MAX(level, 0), 100))] == 0;
}

- (void)stop {
    [_stream setProperty:CFSTR("TorchLevel") value:@0];
    if (_device) [_vendor takeBackDevice:_device forClient:_client informClientWhenDeviceAvailableAgain:NO];
    _stream = nil;
    _device = nil;
    _client = 0;
}

@end
