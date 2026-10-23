#import <Foundation/Foundation.h>

/// The rear flash's two LEDs (white and amber, the 6s's True Tone flash), for Fener.
@interface Torch : NSObject

/// Lights the flash at `level` (0–100) with `warm` percent of it from the amber LED (0 is all
/// white, 100 all amber). Takes the camera device on first use; NO if it can't be had.
- (BOOL)setLevel:(int)level warm:(int)warm;

/// Turns the flash off and gives the camera device back.
- (void)stop;

@end
