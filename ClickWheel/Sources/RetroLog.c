#include <stdarg.h>
#include <stdio.h>
#include <os/log.h>
#include "libretro.h"

// Cores' messages go to the system log ("libretro" category). Some cores (PrBoom) call the log
// callback without checking that the frontend gave one, so every core gets it.
static void retro_log(enum retro_log_level level, const char *format, ...) {
    static os_log_t log;
    if (!log) log = os_log_create("com.ibrahimkoc.clickwheel", "libretro");
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof message, format, args);
    va_end(args);
    os_log_type_t type = level >= RETRO_LOG_ERROR ? OS_LOG_TYPE_ERROR : level == RETRO_LOG_DEBUG ? OS_LOG_TYPE_DEBUG : OS_LOG_TYPE_DEFAULT;
    os_log_with_type(log, type, "%{public}s", message);
}

void retro_frontend_log_interface(struct retro_log_callback *callback) {
    callback->log = retro_log;
}
