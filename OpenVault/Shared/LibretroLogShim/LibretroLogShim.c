#include "include/OpenVaultLibretroLogShim.h"

#include <os/log.h>
#include <stdarg.h>
#include <stdio.h>

enum OpenVaultLibretroLogLevel {
    OpenVaultLibretroLogLevelDebug = 0,
    OpenVaultLibretroLogLevelInfo = 1,
    OpenVaultLibretroLogLevelWarning = 2,
    OpenVaultLibretroLogLevelError = 3,
};

static os_log_type_t openvault_log_type(int level)
{
    switch (level) {
    case OpenVaultLibretroLogLevelDebug:
        return OS_LOG_TYPE_DEBUG;
    case OpenVaultLibretroLogLevelInfo:
        return OS_LOG_TYPE_INFO;
    case OpenVaultLibretroLogLevelWarning:
        return OS_LOG_TYPE_DEFAULT;
    case OpenVaultLibretroLogLevelError:
        return OS_LOG_TYPE_ERROR;
    default:
        return OS_LOG_TYPE_DEFAULT;
    }
}

static void openvault_libretro_log_callback(
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
        os_log_create("org.kennethreitz.OpenVault", "Libretro"),
        openvault_log_type(level),
        "%{public}s",
        message
    );
}

void *openvault_libretro_log_callback_pointer(void)
{
    return (void *)&openvault_libretro_log_callback;
}
