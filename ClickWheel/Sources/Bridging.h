// The libretro API, for Emulator.swift (the cores themselves are loaded with dlopen).
#include "libretro.h"

// RetroLog.c: fills in the log callback (variadic, so it is written in C).
void retro_frontend_log_interface(struct retro_log_callback *callback);
