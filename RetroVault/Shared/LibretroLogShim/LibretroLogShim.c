#include "include/RetroVaultLibretroLogShim.h"

#include <os/log.h>
#include <stdarg.h>
#include <stdio.h>

enum RetroVaultLibretroLogLevel {
    RetroVaultLibretroLogLevelDebug = 0,
    RetroVaultLibretroLogLevelInfo = 1,
    RetroVaultLibretroLogLevelWarning = 2,
    RetroVaultLibretroLogLevelError = 3,
};

static os_log_type_t retrovault_log_type(int level)
{
    switch (level) {
    case RetroVaultLibretroLogLevelDebug:
        return OS_LOG_TYPE_DEBUG;
    case RetroVaultLibretroLogLevelInfo:
        return OS_LOG_TYPE_INFO;
    case RetroVaultLibretroLogLevelWarning:
        return OS_LOG_TYPE_DEFAULT;
    case RetroVaultLibretroLogLevelError:
        return OS_LOG_TYPE_ERROR;
    default:
        return OS_LOG_TYPE_DEFAULT;
    }
}

static void retrovault_libretro_log_callback(
    int level,
    const char *format,
    ...
)
{
    if (format == NULL)
        return;

    char message[4096];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);

    os_log_with_type(
        os_log_create("org.kennethreitz.RetroVault", "Libretro"),
        retrovault_log_type(level),
        "%{public}s",
        message
    );
}

void *retrovault_libretro_log_callback_pointer(void)
{
    return (void *)&retrovault_libretro_log_callback;
}
