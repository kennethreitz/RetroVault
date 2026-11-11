/*
 * RetroVault Vulkan frontend bridge.
 *
 * See RetroVaultVulkanBridge.h. The Libretro ABI and the Vulkan declarations
 * come from the vendored upstream headers; this file owns the instance,
 * surface, device, swapchain, and the blit that puts the core's image on the
 * CAMetalLayer.
 */

#define VK_USE_PLATFORM_METAL_EXT
#define VK_NO_PROTOTYPES

#include "RetroVaultVulkanBridge.h"

#include <libretro/libretro_vulkan.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_beta.h>
#include <vulkan/vulkan_metal.h>

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RV_ACQUIRE_TIMEOUT_NS 100000000ull
#define RV_FENCE_TIMEOUT_NS 1000000000ull
#define RV_MAX_WAIT_SEMAPHORES 8
#define RV_MAX_CORE_COMMAND_BUFFERS 8

static void rv_set_image(
    void *handle,
    const struct retro_vulkan_image *image,
    uint32_t num_semaphores,
    const VkSemaphore *semaphores,
    uint32_t src_queue_family);
static uint32_t rv_get_sync_index(void *handle);
static uint32_t rv_get_sync_index_mask(void *handle);
static void rv_set_command_buffers(
    void *handle,
    uint32_t num_cmd,
    const VkCommandBuffer *cmd);
static void rv_wait_sync_index(void *handle);
static void rv_lock_queue(void *handle);
static void rv_unlock_queue(void *handle);
static void rv_set_signal_semaphore(void *handle, VkSemaphore semaphore);

typedef struct rv_api {
    PFN_vkGetInstanceProcAddr GetInstanceProcAddr;
    PFN_vkCreateInstance CreateInstance;
    PFN_vkEnumerateInstanceExtensionProperties EnumerateInstanceExtensionProperties;
    PFN_vkEnumerateInstanceVersion EnumerateInstanceVersion;

    PFN_vkCreateMetalSurfaceEXT CreateMetalSurfaceEXT;
    PFN_vkEnumeratePhysicalDevices EnumeratePhysicalDevices;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties GetPhysicalDeviceQueueFamilyProperties;
    PFN_vkGetPhysicalDeviceSurfaceSupportKHR GetPhysicalDeviceSurfaceSupportKHR;
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR GetPhysicalDeviceSurfaceCapabilitiesKHR;
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR GetPhysicalDeviceSurfaceFormatsKHR;
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR GetPhysicalDeviceSurfacePresentModesKHR;
    PFN_vkGetPhysicalDeviceProperties GetPhysicalDeviceProperties;
    PFN_vkEnumerateDeviceExtensionProperties EnumerateDeviceExtensionProperties;
    PFN_vkCreateDevice CreateDevice;
    PFN_vkGetDeviceQueue GetDeviceQueue;
    PFN_vkGetDeviceProcAddr GetDeviceProcAddr;
    PFN_vkDestroySurfaceKHR DestroySurfaceKHR;
    PFN_vkDestroyInstance DestroyInstance;

    PFN_vkDestroyDevice DestroyDevice;
    PFN_vkDeviceWaitIdle DeviceWaitIdle;
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkDestroyCommandPool DestroyCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdClearColorImage CmdClearColorImage;
    PFN_vkCmdBlitImage CmdBlitImage;
    PFN_vkCreateSemaphore CreateSemaphore;
    PFN_vkDestroySemaphore DestroySemaphore;
    PFN_vkCreateFence CreateFence;
    PFN_vkDestroyFence DestroyFence;
    PFN_vkWaitForFences WaitForFences;
    PFN_vkResetFences ResetFences;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkCreateSwapchainKHR CreateSwapchainKHR;
    PFN_vkDestroySwapchainKHR DestroySwapchainKHR;
    PFN_vkGetSwapchainImagesKHR GetSwapchainImagesKHR;
    PFN_vkAcquireNextImageKHR AcquireNextImageKHR;
    PFN_vkQueuePresentKHR QueuePresentKHR;
} rv_api;

struct rv_vulkan {
    void *library;
    rv_api api;

    void *metal_layer;
    rv_vulkan_layer_format_fn layer_format;
    void *layer_format_context;

    const struct retro_hw_render_context_negotiation_interface_vulkan *negotiation;

    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue queue;
    VkQueue present_queue;
    uint32_t queue_family;
    uint32_t present_queue_family;

    VkCommandPool command_pool;
    VkCommandBuffer command_buffer;
    VkFence fence;
    VkSemaphore acquire_semaphore;
    VkSemaphore render_semaphore;

    VkSwapchainKHR swapchain;
    VkImage swapchain_images[8];
    VkFormat swapchain_format;
    VkExtent2D swapchain_extent;
    _Atomic uint32_t swapchain_image_count;
    _Atomic int swapchain_srgb;

    _Atomic uint32_t drawable_width;
    _Atomic uint32_t drawable_height;
    _Atomic bool need_recreate;
    _Atomic uint32_t current_index;

    struct retro_vulkan_image image;
    bool has_image;
    bool frame_acquired;
    VkImage image_handle;
    VkImageLayout image_layout;
    VkFormat image_format;
    uint32_t image_width;
    uint32_t image_height;

    VkSemaphore wait_semaphores[RV_MAX_WAIT_SEMAPHORES];
    uint32_t wait_semaphore_count;
    VkSemaphore signal_semaphore;

    VkCommandBuffer core_command_buffers[RV_MAX_CORE_COMMAND_BUFFERS];
    uint32_t core_command_buffer_count;

    struct retro_hw_render_interface_vulkan interface;
    pthread_mutex_t queue_lock;
    pthread_mutex_t image_lock;
    bool started;
};

static void rv_error(char *destination, size_t size, const char *format, ...)
{
    if (destination == NULL || size == 0)
        return;

    va_list arguments;
    va_start(arguments, format);
    vsnprintf(destination, size, format, arguments);
    va_end(arguments);
}

/* MoltenVK stays loaded for the process lifetime. A core may still hold
 * function pointers from it after the frontend's context is gone. */
static void *rv_moltenvk;
static char rv_moltenvk_path[PATH_MAX];

static void rv_log(const char *format, ...)
{
    va_list arguments;
    fputs("[vulkan] ", stderr);
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
    fputc('\n', stderr);
}

static void *rv_symbol(void *library, const char *name)
{
    return dlsym(library, name);
}

static bool rv_load_global_functions(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    vulkan->api.GetInstanceProcAddr =
        (PFN_vkGetInstanceProcAddr)rv_symbol(
            vulkan->library,
            "vkGetInstanceProcAddr");
    vulkan->api.CreateInstance = (PFN_vkCreateInstance)rv_symbol(
        vulkan->library,
        "vkCreateInstance");
    vulkan->api.EnumerateInstanceExtensionProperties =
        (PFN_vkEnumerateInstanceExtensionProperties)rv_symbol(
            vulkan->library,
            "vkEnumerateInstanceExtensionProperties");
    vulkan->api.EnumerateInstanceVersion =
        (PFN_vkEnumerateInstanceVersion)rv_symbol(
            vulkan->library,
            "vkEnumerateInstanceVersion");

    if (vulkan->api.GetInstanceProcAddr == NULL
        || vulkan->api.CreateInstance == NULL
        || vulkan->api.EnumerateInstanceExtensionProperties == NULL) {
        rv_error(
            error,
            error_size,
            "MoltenVK is missing its Vulkan entry points.");
        return false;
    }
    return true;
}

#define RV_LOAD_INSTANCE(vulkan, name)                                        \
    do {                                                                      \
        (vulkan)->api.name =                                                  \
            (PFN_vk##name)(vulkan)->api.GetInstanceProcAddr(                    \
                (vulkan)->instance, "vk" #name);                                   \
        if ((vulkan)->api.name == NULL) {                                     \
            rv_error(                                                         \
                error,                                                        \
                error_size,                                                   \
                "MoltenVK is missing %s.",                                    \
                #name);                                                       \
            return false;                                                     \
        }                                                                     \
    } while (0)

#define RV_LOAD_DEVICE(vulkan, name)                                          \
    do {                                                                      \
        (vulkan)->api.name =                                                  \
            (PFN_vk##name)(vulkan)->api.GetDeviceProcAddr(                      \
                (vulkan)->device, "vk" #name);                                     \
        if ((vulkan)->api.name == NULL) {                                     \
            rv_error(                                                         \
                error,                                                        \
                error_size,                                                   \
                "MoltenVK is missing %s.",                                    \
                #name);                                                       \
            return false;                                                     \
        }                                                                     \
    } while (0)

static bool rv_create_instance(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    uint32_t extension_count = 0;
    VkResult result =
        vulkan->api.EnumerateInstanceExtensionProperties(
            NULL,
            &extension_count,
            NULL);
    if (result != VK_SUCCESS || extension_count == 0) {
        rv_error(
            error,
            error_size,
            "MoltenVK reported no instance extensions (VkResult %d).",
            (int)result);
        return false;
    }

    VkExtensionProperties *extensions = calloc(
        extension_count,
        sizeof(*extensions));
    if (extensions == NULL) {
        rv_error(error, error_size, "Out of memory reading MoltenVK extensions.");
        return false;
    }
    result = vulkan->api.EnumerateInstanceExtensionProperties(
        NULL,
        &extension_count,
        extensions);

    bool has_surface = false;
    bool has_metal_surface = false;
    bool has_portability = false;
    bool has_properties2 = false;
    bool has_external_memory = false;
    bool has_external_semaphore = false;
    bool has_external_fence = false;
    bool has_surface_capabilities2 = false;
    if (result == VK_SUCCESS) {
        for (uint32_t index = 0; index < extension_count; index++) {
            const char *name = extensions[index].extensionName;
            if (strcmp(name, VK_KHR_SURFACE_EXTENSION_NAME) == 0)
                has_surface = true;
            else if (strcmp(name, VK_EXT_METAL_SURFACE_EXTENSION_NAME) == 0)
                has_metal_surface = true;
            else if (strcmp(
                         name,
                         VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
                     == 0)
                has_portability = true;
            else if (strcmp(
                         name,
                         VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME)
                     == 0)
                has_properties2 = true;
            else if (strcmp(
                         name,
                         VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME)
                     == 0)
                has_external_memory = true;
            else if (strcmp(
                         name,
                         VK_KHR_EXTERNAL_SEMAPHORE_CAPABILITIES_EXTENSION_NAME)
                     == 0)
                has_external_semaphore = true;
            else if (strcmp(
                         name,
                         VK_KHR_EXTERNAL_FENCE_CAPABILITIES_EXTENSION_NAME)
                     == 0)
                has_external_fence = true;
            else if (strcmp(
                         name,
                         VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME)
                     == 0)
                has_surface_capabilities2 = true;
        }
    }
    free(extensions);

    if (!has_surface || !has_metal_surface) {
        rv_error(
            error,
            error_size,
            "MoltenVK is missing the Metal surface extensions.");
        return false;
    }

    const char *enabled[9];
    uint32_t enabled_count = 0;
    enabled[enabled_count++] = VK_KHR_SURFACE_EXTENSION_NAME;
    enabled[enabled_count++] = VK_EXT_METAL_SURFACE_EXTENSION_NAME;
    if (has_portability)
        enabled[enabled_count++] =
            VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    if (has_properties2)
        enabled[enabled_count++] =
            VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME;
    if (has_external_memory)
        enabled[enabled_count++] =
            VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME;
    if (has_external_semaphore)
        enabled[enabled_count++] =
            VK_KHR_EXTERNAL_SEMAPHORE_CAPABILITIES_EXTENSION_NAME;
    if (has_external_fence)
        enabled[enabled_count++] =
            VK_KHR_EXTERNAL_FENCE_CAPABILITIES_EXTENSION_NAME;
    if (has_surface_capabilities2)
        enabled[enabled_count++] =
            VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME;

    const VkApplicationInfo *application_info = NULL;
    if (vulkan->negotiation != NULL
        && vulkan->negotiation->get_application_info != NULL) {
        application_info = vulkan->negotiation->get_application_info();
    }

    VkApplicationInfo application_info_copy;
    memset(&application_info_copy, 0, sizeof(application_info_copy));
    if (application_info != NULL) {
        application_info_copy = *application_info;
    } else {
        application_info_copy.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        application_info_copy.pApplicationName = "RetroVault";
        application_info_copy.pEngineName = "RetroVault";
    }
    /* A core that asks for 1.0 still gets the 1.1 instance facilities the
     * frontend and its extensions rely on. The core's device creation is
     * unaffected. */
    if (application_info_copy.apiVersion < VK_API_VERSION_1_1) {
        application_info_copy.apiVersion = VK_API_VERSION_1_1;
    }

    VkInstanceCreateInfo create_info;
    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &application_info_copy;
    create_info.enabledExtensionCount = enabled_count;
    create_info.ppEnabledExtensionNames = enabled;
    if (has_portability)
        create_info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;

    result = vulkan->api.CreateInstance(
        &create_info,
        NULL,
        &vulkan->instance);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateInstance failed (VkResult %d).",
            (int)result);
        return false;
    }

    RV_LOAD_INSTANCE(vulkan, CreateMetalSurfaceEXT);
    RV_LOAD_INSTANCE(vulkan, EnumeratePhysicalDevices);
    RV_LOAD_INSTANCE(vulkan, GetPhysicalDeviceQueueFamilyProperties);
    RV_LOAD_INSTANCE(vulkan, GetPhysicalDeviceSurfaceSupportKHR);
    RV_LOAD_INSTANCE(vulkan, GetPhysicalDeviceSurfaceCapabilitiesKHR);
    RV_LOAD_INSTANCE(vulkan, GetPhysicalDeviceSurfaceFormatsKHR);
    RV_LOAD_INSTANCE(vulkan, GetPhysicalDeviceSurfacePresentModesKHR);
    RV_LOAD_INSTANCE(vulkan, GetPhysicalDeviceProperties);
    RV_LOAD_INSTANCE(vulkan, EnumerateDeviceExtensionProperties);
    RV_LOAD_INSTANCE(vulkan, CreateDevice);
    RV_LOAD_INSTANCE(vulkan, GetDeviceQueue);
    RV_LOAD_INSTANCE(vulkan, GetDeviceProcAddr);
    RV_LOAD_INSTANCE(vulkan, DestroySurfaceKHR);
    RV_LOAD_INSTANCE(vulkan, DestroyInstance);
    RV_LOAD_INSTANCE(vulkan, CreateSwapchainKHR);
    RV_LOAD_INSTANCE(vulkan, DestroySwapchainKHR);
    RV_LOAD_INSTANCE(vulkan, GetSwapchainImagesKHR);
    RV_LOAD_INSTANCE(vulkan, AcquireNextImageKHR);
    RV_LOAD_INSTANCE(vulkan, QueuePresentKHR);

    return true;
}

static bool rv_create_surface(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    VkMetalSurfaceCreateInfoEXT create_info;
    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
    create_info.pLayer = (const CAMetalLayer *)vulkan->metal_layer;

    VkResult result = vulkan->api.CreateMetalSurfaceEXT(
        vulkan->instance,
        &create_info,
        NULL,
        &vulkan->surface);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateMetalSurfaceEXT failed (VkResult %d).",
            (int)result);
        return false;
    }
    return true;
}

static bool rv_pick_physical_device(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    uint32_t device_count = 0;
    VkResult result = vulkan->api.EnumeratePhysicalDevices(
        vulkan->instance,
        &device_count,
        NULL);
    if (result != VK_SUCCESS || device_count == 0) {
        rv_error(
            error,
            error_size,
            "MoltenVK reported no Vulkan physical devices (VkResult %d).",
            (int)result);
        return false;
    }

    VkPhysicalDevice *devices = calloc(device_count, sizeof(*devices));
    if (devices == NULL) {
        rv_error(error, error_size, "Out of memory reading Vulkan devices.");
        return false;
    }
    result = vulkan->api.EnumeratePhysicalDevices(
        vulkan->instance,
        &device_count,
        devices);
    if (result != VK_SUCCESS) {
        free(devices);
        rv_error(
            error,
            error_size,
            "vkEnumeratePhysicalDevices failed (VkResult %d).",
            (int)result);
        return false;
    }

    for (uint32_t device_index = 0;
         device_index < device_count;
         device_index++) {
        VkPhysicalDevice device = devices[device_index];
        uint32_t family_count = 0;
        vulkan->api.GetPhysicalDeviceQueueFamilyProperties(
            device,
            &family_count,
            NULL);
        if (family_count == 0)
            continue;

        VkQueueFamilyProperties *families = calloc(
            family_count,
            sizeof(*families));
        if (families == NULL)
            continue;
        vulkan->api.GetPhysicalDeviceQueueFamilyProperties(
            device,
            &family_count,
            families);

        for (uint32_t family = 0; family < family_count; family++) {
            if ((families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) == 0)
                continue;

            VkBool32 supports_present = VK_FALSE;
            result = vulkan->api.GetPhysicalDeviceSurfaceSupportKHR(
                device,
                family,
                vulkan->surface,
                &supports_present);
            if (result == VK_SUCCESS && supports_present == VK_TRUE) {
                vulkan->physical_device = device;
                vulkan->queue_family = family;
                vulkan->present_queue_family = family;
                break;
            }
        }
        free(families);
        if (vulkan->physical_device != VK_NULL_HANDLE)
            break;
    }
    free(devices);

    if (vulkan->physical_device == VK_NULL_HANDLE) {
        rv_error(
            error,
            error_size,
            "No Vulkan device exposes a graphics queue that can present.");
        return false;
    }

    VkPhysicalDeviceProperties properties;
    vulkan->api.GetPhysicalDeviceProperties(
        vulkan->physical_device,
        &properties);
    rv_log(
        "device: %s (Vulkan %u.%u.%u)",
        properties.deviceName,
        VK_API_VERSION_MAJOR(properties.apiVersion),
        VK_API_VERSION_MINOR(properties.apiVersion),
        VK_API_VERSION_PATCH(properties.apiVersion));
    return true;
}

static bool rv_device_has_extension(
    rv_vulkan *vulkan,
    const char *name)
{
    uint32_t extension_count = 0;
    VkResult result = vulkan->api.EnumerateDeviceExtensionProperties(
        vulkan->physical_device,
        NULL,
        &extension_count,
        NULL);
    if (result != VK_SUCCESS || extension_count == 0)
        return false;

    VkExtensionProperties *extensions = calloc(
        extension_count,
        sizeof(*extensions));
    if (extensions == NULL)
        return false;
    result = vulkan->api.EnumerateDeviceExtensionProperties(
        vulkan->physical_device,
        NULL,
        &extension_count,
        extensions);

    bool found = false;
    if (result == VK_SUCCESS) {
        for (uint32_t index = 0; index < extension_count; index++) {
            if (strcmp(extensions[index].extensionName, name) == 0) {
                found = true;
                break;
            }
        }
    }
    free(extensions);
    return found;
}

static bool rv_create_device_fallback(
    rv_vulkan *vulkan,
    const char *const *extensions,
    uint32_t extension_count,
    char *error,
    size_t error_size)
{
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_infos[2];
    uint32_t queue_info_count = 0;

    memset(queue_infos, 0, sizeof(queue_infos));
    queue_infos[0].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_infos[0].queueFamilyIndex = vulkan->queue_family;
    queue_infos[0].queueCount = 1;
    queue_infos[0].pQueuePriorities = &priority;
    queue_info_count = 1;

    if (vulkan->present_queue_family != vulkan->queue_family) {
        queue_infos[1].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_infos[1].queueFamilyIndex = vulkan->present_queue_family;
        queue_infos[1].queueCount = 1;
        queue_infos[1].pQueuePriorities = &priority;
        queue_info_count = 2;
    }

    VkPhysicalDeviceFeatures features;
    memset(&features, 0, sizeof(features));

    VkDeviceCreateInfo create_info;
    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    create_info.queueCreateInfoCount = queue_info_count;
    create_info.pQueueCreateInfos = queue_infos;
    create_info.enabledExtensionCount = extension_count;
    create_info.ppEnabledExtensionNames = extensions;
    create_info.pEnabledFeatures = &features;

    VkResult result = vulkan->api.CreateDevice(
        vulkan->physical_device,
        &create_info,
        NULL,
        &vulkan->device);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateDevice failed (VkResult %d).",
            (int)result);
        return false;
    }

    vulkan->api.GetDeviceQueue(
        vulkan->device,
        vulkan->queue_family,
        0,
        &vulkan->queue);
    vulkan->present_queue = vulkan->queue;
    if (vulkan->present_queue_family != vulkan->queue_family) {
        vulkan->api.GetDeviceQueue(
            vulkan->device,
            vulkan->present_queue_family,
            0,
            &vulkan->present_queue);
    }
    return true;
}

static bool rv_create_device(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    const char *extensions[2];
    uint32_t extension_count = 0;
    if (rv_device_has_extension(
            vulkan,
            VK_KHR_SWAPCHAIN_EXTENSION_NAME)) {
        extensions[extension_count++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    } else {
        rv_error(
            error,
            error_size,
            "The Vulkan device does not support VK_KHR_swapchain.");
        return false;
    }
    if (rv_device_has_extension(
            vulkan,
            VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME)) {
        extensions[extension_count++] =
            VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME;
    }

    if (vulkan->negotiation != NULL
        && vulkan->negotiation->create_device != NULL) {
        struct retro_vulkan_context context;
        memset(&context, 0, sizeof(context));
        VkPhysicalDeviceFeatures required_features;
        memset(&required_features, 0, sizeof(required_features));

        const bool created = vulkan->negotiation->create_device(
            &context,
            vulkan->instance,
            vulkan->physical_device,
            vulkan->surface,
            vulkan->api.GetInstanceProcAddr,
            extensions,
            extension_count,
            NULL,
            0,
            &required_features);
        if (created && context.device != VK_NULL_HANDLE
            && context.queue != VK_NULL_HANDLE) {
            if (context.gpu != VK_NULL_HANDLE)
                vulkan->physical_device = context.gpu;
            vulkan->device = context.device;
            vulkan->queue = context.queue;
            vulkan->queue_family = context.queue_family_index;
            vulkan->present_queue = context.presentation_queue != VK_NULL_HANDLE
                ? context.presentation_queue
                : context.queue;
            vulkan->present_queue_family =
                context.presentation_queue != VK_NULL_HANDLE
                ? context.presentation_queue_family_index
                : context.queue_family_index;
            rv_log(
                "device created by the core's negotiation interface");
            return true;
        }

        rv_log(
            "the core's negotiation interface did not create a device; "
            "falling back to the frontend's device");
    }

    return rv_create_device_fallback(
        vulkan,
        extensions,
        extension_count,
        error,
        error_size);
}

static bool rv_create_swapchain(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    const uint32_t width = atomic_load(&vulkan->drawable_width);
    const uint32_t height = atomic_load(&vulkan->drawable_height);
    if (width == 0 || height == 0) {
        /* The view has not been laid out yet. Keep the core running and
         * present nothing until it has a size. */
        return true;
    }

    VkSurfaceCapabilitiesKHR capabilities;
    VkResult result = vulkan->api.GetPhysicalDeviceSurfaceCapabilitiesKHR(
        vulkan->physical_device,
        vulkan->surface,
        &capabilities);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed (VkResult %d).",
            (int)result);
        return false;
    }

    uint32_t format_count = 0;
    result = vulkan->api.GetPhysicalDeviceSurfaceFormatsKHR(
        vulkan->physical_device,
        vulkan->surface,
        &format_count,
        NULL);
    if (result != VK_SUCCESS || format_count == 0) {
        rv_error(
            error,
            error_size,
            "The Metal surface reported no formats (VkResult %d).",
            (int)result);
        return false;
    }
    VkSurfaceFormatKHR *formats = calloc(format_count, sizeof(*formats));
    if (formats == NULL) {
        rv_error(error, error_size, "Out of memory reading surface formats.");
        return false;
    }
    result = vulkan->api.GetPhysicalDeviceSurfaceFormatsKHR(
        vulkan->physical_device,
        vulkan->surface,
        &format_count,
        formats);
    if (result != VK_SUCCESS) {
        free(formats);
        rv_error(
            error,
            error_size,
            "vkGetPhysicalDeviceSurfaceFormatsKHR failed (VkResult %d).",
            (int)result);
        return false;
    }

    pthread_mutex_lock(&vulkan->image_lock);
    const VkFormat core_format = vulkan->image_format;
    pthread_mutex_unlock(&vulkan->image_lock);
    const bool wants_srgb =
        core_format == VK_FORMAT_R8G8B8A8_SRGB
        || core_format == VK_FORMAT_B8G8R8A8_SRGB;
    VkSurfaceFormatKHR chosen = formats[0];
    bool found_format = false;
    for (uint32_t index = 0; index < format_count; index++) {
        const VkSurfaceFormatKHR candidate = formats[index];
        const bool candidate_srgb =
            candidate.format == VK_FORMAT_B8G8R8A8_SRGB
            || candidate.format == VK_FORMAT_R8G8B8A8_SRGB;
        const bool candidate_linear =
            candidate.format == VK_FORMAT_B8G8R8A8_UNORM
            || candidate.format == VK_FORMAT_R8G8B8A8_UNORM;
        if (candidate_srgb == wants_srgb
            && (candidate_linear || candidate_srgb)) {
            chosen = candidate;
            found_format = true;
            break;
        }
    }
    free(formats);
    if (!found_format) {
        rv_error(
            error,
            error_size,
            "The Metal surface has no 8-bit format matching the core image.");
        return false;
    }

    if (vulkan->layer_format != NULL
        && atomic_load(&vulkan->swapchain_srgb) != (wants_srgb ? 1 : 0)) {
        vulkan->layer_format(
            vulkan->layer_format_context,
            wants_srgb);
    }
    atomic_store(&vulkan->swapchain_srgb, wants_srgb ? 1 : 0);

    uint32_t present_mode_count = 0;
    result = vulkan->api.GetPhysicalDeviceSurfacePresentModesKHR(
        vulkan->physical_device,
        vulkan->surface,
        &present_mode_count,
        NULL);
    if (result != VK_SUCCESS || present_mode_count == 0) {
        rv_error(
            error,
            error_size,
            "The Metal surface reported no present modes (VkResult %d).",
            (int)result);
        return false;
    }
    VkPresentModeKHR *present_modes = calloc(
        present_mode_count,
        sizeof(*present_modes));
    if (present_modes == NULL) {
        rv_error(error, error_size, "Out of memory reading present modes.");
        return false;
    }
    result = vulkan->api.GetPhysicalDeviceSurfacePresentModesKHR(
        vulkan->physical_device,
        vulkan->surface,
        &present_mode_count,
        present_modes);
    if (result != VK_SUCCESS) {
        free(present_modes);
        rv_error(
            error,
            error_size,
            "vkGetPhysicalDeviceSurfacePresentModesKHR failed (VkResult %d).",
            (int)result);
        return false;
    }

    VkPresentModeKHR present_mode = VK_PRESENT_MODE_FIFO_KHR;
    for (uint32_t index = 0; index < present_mode_count; index++) {
        if (present_modes[index] == VK_PRESENT_MODE_MAILBOX_KHR) {
            present_mode = VK_PRESENT_MODE_MAILBOX_KHR;
            break;
        }
    }
    if (present_mode == VK_PRESENT_MODE_FIFO_KHR) {
        for (uint32_t index = 0; index < present_mode_count; index++) {
            if (present_modes[index] == VK_PRESENT_MODE_IMMEDIATE_KHR) {
                present_mode = VK_PRESENT_MODE_IMMEDIATE_KHR;
                break;
            }
        }
    }
    free(present_modes);

    VkExtent2D extent = capabilities.currentExtent;
    if (extent.width == UINT32_MAX || extent.height == UINT32_MAX) {
        extent.width = width;
        extent.height = height;
        if (extent.width < capabilities.minImageExtent.width)
            extent.width = capabilities.minImageExtent.width;
        if (extent.height < capabilities.minImageExtent.height)
            extent.height = capabilities.minImageExtent.height;
        if (extent.width > capabilities.maxImageExtent.width)
            extent.width = capabilities.maxImageExtent.width;
        if (extent.height > capabilities.maxImageExtent.height)
            extent.height = capabilities.maxImageExtent.height;
    }
    if (extent.width == 0 || extent.height == 0)
        return true;

    uint32_t image_count = capabilities.minImageCount + 1;
    if (image_count < 2)
        image_count = 2;
    if (image_count > 3)
        image_count = 3;
    if (capabilities.maxImageCount != 0
        && image_count > capabilities.maxImageCount) {
        image_count = capabilities.maxImageCount;
    }

    VkCompositeAlphaFlagBitsKHR composite_alpha =
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if ((capabilities.supportedCompositeAlpha
         & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
        == 0) {
        composite_alpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    }

    VkSwapchainCreateInfoKHR create_info;
    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    create_info.surface = vulkan->surface;
    create_info.minImageCount = image_count;
    create_info.imageFormat = chosen.format;
    create_info.imageColorSpace = chosen.colorSpace;
    create_info.imageExtent = extent;
    create_info.imageArrayLayers = 1;
    create_info.imageUsage =
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
        | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    create_info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    create_info.preTransform = capabilities.currentTransform;
    create_info.compositeAlpha = composite_alpha;
    create_info.presentMode = present_mode;
    create_info.clipped = VK_TRUE;

    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    result = vulkan->api.CreateSwapchainKHR(
        vulkan->device,
        &create_info,
        NULL,
        &swapchain);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateSwapchainKHR failed (VkResult %d).",
            (int)result);
        return false;
    }

    vulkan->swapchain = swapchain;
    vulkan->swapchain_format = chosen.format;
    vulkan->swapchain_extent = extent;
    atomic_store(&vulkan->need_recreate, false);

    uint32_t actual_image_count = 0;
    result = vulkan->api.GetSwapchainImagesKHR(
        vulkan->device,
        vulkan->swapchain,
        &actual_image_count,
        NULL);
    if (result != VK_SUCCESS || actual_image_count == 0
        || actual_image_count > 8) {
        rv_error(
            error,
            error_size,
            "vkGetSwapchainImagesKHR failed (VkResult %d).",
            (int)result);
        return false;
    }
    memset(
        vulkan->swapchain_images,
        0,
        sizeof(vulkan->swapchain_images));
    result = vulkan->api.GetSwapchainImagesKHR(
        vulkan->device,
        vulkan->swapchain,
        &actual_image_count,
        vulkan->swapchain_images);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkGetSwapchainImagesKHR failed (VkResult %d).",
            (int)result);
        return false;
    }
    atomic_store(&vulkan->swapchain_image_count, actual_image_count);

    rv_log(
        "swapchain: %ux%u, %u images, format %d, present mode %d",
        extent.width,
        extent.height,
        actual_image_count,
        (int)chosen.format,
        (int)present_mode);
    return true;
}

static void rv_destroy_swapchain(rv_vulkan *vulkan)
{
    if (vulkan->swapchain != VK_NULL_HANDLE) {
        vulkan->api.DestroySwapchainKHR(
            vulkan->device,
            vulkan->swapchain,
            NULL);
        vulkan->swapchain = VK_NULL_HANDLE;
    }
    memset(
        vulkan->swapchain_images,
        0,
        sizeof(vulkan->swapchain_images));
    atomic_store(&vulkan->swapchain_image_count, 0);
}

static bool rv_create_commands_and_sync(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    VkCommandPoolCreateInfo pool_info;
    memset(&pool_info, 0, sizeof(pool_info));
    pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = vulkan->queue_family;
    VkResult result = vulkan->api.CreateCommandPool(
        vulkan->device,
        &pool_info,
        NULL,
        &vulkan->command_pool);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateCommandPool failed (VkResult %d).",
            (int)result);
        return false;
    }

    VkCommandBufferAllocateInfo allocate_info;
    memset(&allocate_info, 0, sizeof(allocate_info));
    allocate_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocate_info.commandPool = vulkan->command_pool;
    allocate_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate_info.commandBufferCount = 1;
    result = vulkan->api.AllocateCommandBuffers(
        vulkan->device,
        &allocate_info,
        &vulkan->command_buffer);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkAllocateCommandBuffers failed (VkResult %d).",
            (int)result);
        return false;
    }

    VkFenceCreateInfo fence_info;
    memset(&fence_info, 0, sizeof(fence_info));
    fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    /* Signaled so the first frame does not wait on a fence that has never
     * been submitted. Every present resets it before submitting. */
    fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    result = vulkan->api.CreateFence(
        vulkan->device,
        &fence_info,
        NULL,
        &vulkan->fence);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateFence failed (VkResult %d).",
            (int)result);
        return false;
    }

    VkSemaphoreCreateInfo semaphore_info;
    memset(&semaphore_info, 0, sizeof(semaphore_info));
    semaphore_info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    result = vulkan->api.CreateSemaphore(
        vulkan->device,
        &semaphore_info,
        NULL,
        &vulkan->acquire_semaphore);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateSemaphore failed (VkResult %d).",
            (int)result);
        return false;
    }
    result = vulkan->api.CreateSemaphore(
        vulkan->device,
        &semaphore_info,
        NULL,
        &vulkan->render_semaphore);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkCreateSemaphore failed (VkResult %d).",
            (int)result);
        return false;
    }
    return true;
}

static void rv_fill_interface(rv_vulkan *vulkan)
{
    struct retro_hw_render_interface_vulkan *interface = &vulkan->interface;
    memset(interface, 0, sizeof(*interface));
    interface->interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
    interface->interface_version =
        RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    interface->handle = vulkan;
    interface->instance = vulkan->instance;
    interface->gpu = vulkan->physical_device;
    interface->device = vulkan->device;
    interface->get_device_proc_addr = vulkan->api.GetDeviceProcAddr;
    interface->get_instance_proc_addr = vulkan->api.GetInstanceProcAddr;
    interface->queue = vulkan->queue;
    interface->queue_index = vulkan->queue_family;
    interface->set_image = rv_set_image;
    interface->get_sync_index = rv_get_sync_index;
    interface->get_sync_index_mask = rv_get_sync_index_mask;
    interface->set_command_buffers = rv_set_command_buffers;
    interface->wait_sync_index = rv_wait_sync_index;
    interface->lock_queue = rv_lock_queue;
    interface->unlock_queue = rv_unlock_queue;
    interface->set_signal_semaphore = rv_set_signal_semaphore;
}

static void rv_set_image(
    void *handle,
    const struct retro_vulkan_image *image,
    uint32_t num_semaphores,
    const VkSemaphore *semaphores,
    uint32_t src_queue_family)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    if (vulkan == NULL)
        return;

    pthread_mutex_lock(&vulkan->image_lock);

    if (image == NULL) {
        vulkan->has_image = false;
        vulkan->image_handle = VK_NULL_HANDLE;
        vulkan->wait_semaphore_count = 0;
        pthread_mutex_unlock(&vulkan->image_lock);
        return;
    }

    vulkan->image = *image;
    vulkan->has_image = true;
    vulkan->image_handle = image->create_info.image;
    vulkan->image_layout = image->image_layout;
    vulkan->image_format = image->create_info.format;

    vulkan->wait_semaphore_count = 0;
    if (num_semaphores > RV_MAX_WAIT_SEMAPHORES)
        num_semaphores = RV_MAX_WAIT_SEMAPHORES;
    for (uint32_t index = 0; index < num_semaphores; index++) {
        vulkan->wait_semaphores[index] = semaphores[index];
    }
    vulkan->wait_semaphore_count = num_semaphores;
    pthread_mutex_unlock(&vulkan->image_lock);

    const bool srgb =
        vulkan->image_format == VK_FORMAT_R8G8B8A8_SRGB
        || vulkan->image_format == VK_FORMAT_B8G8R8A8_SRGB;
    const int swapchain_srgb = atomic_load(&vulkan->swapchain_srgb);
    if (swapchain_srgb >= 0
        && swapchain_srgb != (srgb ? 1 : 0)) {
        atomic_store(&vulkan->need_recreate, true);
    }

    if (src_queue_family != VK_QUEUE_FAMILY_IGNORED
        && src_queue_family != vulkan->queue_family) {
        /* The scoped cores render on the shared queue, so a cross-family
         * handover is not expected. Record it rather than silently misrender. */
        rv_log(
            "core image is on queue family %u; presenting on %u "
            "(cross-family ownership is not implemented)",
            src_queue_family,
            vulkan->queue_family);
    }
}

static uint32_t rv_get_sync_index(void *handle)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    return vulkan != NULL ? atomic_load(&vulkan->current_index) : 0;
}

static uint32_t rv_get_sync_index_mask(void *handle)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    if (vulkan == NULL)
        return 1;
    const uint32_t count = atomic_load(&vulkan->swapchain_image_count);
    if (count == 0)
        return 1;
    return (1u << count) - 1u;
}

static void rv_set_command_buffers(
    void *handle,
    uint32_t num_cmd,
    const VkCommandBuffer *cmd)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    if (vulkan == NULL)
        return;

    if (num_cmd > RV_MAX_CORE_COMMAND_BUFFERS)
        num_cmd = RV_MAX_CORE_COMMAND_BUFFERS;
    pthread_mutex_lock(&vulkan->image_lock);
    for (uint32_t index = 0; index < num_cmd; index++)
        vulkan->core_command_buffers[index] = cmd[index];
    vulkan->core_command_buffer_count = num_cmd;
    pthread_mutex_unlock(&vulkan->image_lock);
}

static void rv_wait_sync_index(void *handle)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    if (vulkan == NULL || vulkan->device == VK_NULL_HANDLE)
        return;
    vulkan->api.WaitForFences(
        vulkan->device,
        1,
        &vulkan->fence,
        VK_TRUE,
        RV_FENCE_TIMEOUT_NS);
}

static void rv_lock_queue(void *handle)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    if (vulkan != NULL)
        pthread_mutex_lock(&vulkan->queue_lock);
}

static void rv_unlock_queue(void *handle)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    if (vulkan != NULL)
        pthread_mutex_unlock(&vulkan->queue_lock);
}

static void rv_set_signal_semaphore(
    void *handle,
    VkSemaphore semaphore)
{
    rv_vulkan *vulkan = (rv_vulkan *)handle;
    if (vulkan == NULL)
        return;
    pthread_mutex_lock(&vulkan->image_lock);
    vulkan->signal_semaphore = semaphore;
    pthread_mutex_unlock(&vulkan->image_lock);
}

static void rv_image_barrier(
    rv_vulkan *vulkan,
    VkCommandBuffer command_buffer,
    VkImage image,
    VkImageLayout old_layout,
    VkImageLayout new_layout,
    VkPipelineStageFlags source_stage,
    VkPipelineStageFlags destination_stage,
    VkAccessFlags source_access,
    VkAccessFlags destination_access)
{
    VkImageMemoryBarrier barrier;
    memset(&barrier, 0, sizeof(barrier));
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcAccessMask = source_access;
    barrier.dstAccessMask = destination_access;

    vulkan->api.CmdPipelineBarrier(
        command_buffer,
        source_stage,
        destination_stage,
        0,
        0,
        NULL,
        0,
        NULL,
        1,
        &barrier);
}

static void rv_destination_rect(
    uint32_t source_width,
    uint32_t source_height,
    float aspect_ratio,
    uint32_t target_width,
    uint32_t target_height,
    VkOffset3D *minimum,
    VkOffset3D *maximum,
    VkFilter *filter)
{
    if (source_width == 0 || source_height == 0) {
        source_width = target_width;
        source_height = target_height;
    }

    float target_aspect = aspect_ratio > 0
        ? aspect_ratio
        : (float)source_width / (float)source_height;
    if (!(target_aspect > 0))
        target_aspect = (float)source_width / (float)source_height;

    uint32_t destination_width;
    uint32_t destination_height;
    const float view_aspect =
        (float)target_width / (float)target_height;
    if (target_aspect > view_aspect) {
        destination_width = target_width;
        destination_height =
            (uint32_t)((float)target_width / target_aspect + 0.5f);
    } else {
        destination_height = target_height;
        destination_width =
            (uint32_t)((float)target_height * target_aspect + 0.5f);
    }
    if (destination_width == 0)
        destination_width = 1;
    if (destination_height == 0)
        destination_height = 1;
    if (destination_width > target_width)
        destination_width = target_width;
    if (destination_height > target_height)
        destination_height = target_height;

    const int32_t x = ((int32_t)target_width - (int32_t)destination_width) / 2;
    const int32_t y = ((int32_t)target_height - (int32_t)destination_height) / 2;

    minimum->x = x;
    minimum->y = y;
    minimum->z = 0;
    maximum->x = x + (int32_t)destination_width;
    maximum->y = y + (int32_t)destination_height;
    maximum->z = 1;

    const bool integer_scale =
        destination_width >= source_width
        && destination_height >= source_height
        && destination_width % source_width == 0
        && destination_height % source_height == 0;
    *filter = integer_scale ? VK_FILTER_NEAREST : VK_FILTER_LINEAR;
}

static bool rv_record(
    rv_vulkan *vulkan,
    uint32_t image_index,
    bool has_image,
    VkImage core_image,
    VkImageLayout core_layout,
    uint32_t width,
    uint32_t height,
    float aspect_ratio,
    char *error,
    size_t error_size)
{
    if (image_index >= atomic_load(&vulkan->swapchain_image_count)) {
        rv_error(error, error_size, "Swapchain image index is out of range.");
        return false;
    }

    VkImage swapchain_image = vulkan->swapchain_images[image_index];

    VkResult result = VK_SUCCESS;
    VkCommandBufferBeginInfo begin_info;
    memset(&begin_info, 0, sizeof(begin_info));
    begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    result = vulkan->api.BeginCommandBuffer(
        vulkan->command_buffer,
        &begin_info);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkBeginCommandBuffer failed (VkResult %d).",
            (int)result);
        return false;
    }

    rv_image_barrier(
        vulkan,
        vulkan->command_buffer,
        swapchain_image,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        VK_ACCESS_TRANSFER_WRITE_BIT);

    const VkClearColorValue clear_color = {
        { 0.0f, 0.0f, 0.0f, 1.0f }
    };
    VkImageSubresourceRange clear_range;
    memset(&clear_range, 0, sizeof(clear_range));
    clear_range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    clear_range.levelCount = 1;
    clear_range.layerCount = 1;
    vulkan->api.CmdClearColorImage(
        vulkan->command_buffer,
        swapchain_image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        &clear_color,
        1,
        &clear_range);

    rv_image_barrier(
        vulkan,
        vulkan->command_buffer,
        swapchain_image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_ACCESS_TRANSFER_WRITE_BIT);

    if (has_image
        && core_image != VK_NULL_HANDLE
        && width > 0
        && height > 0) {
        rv_image_barrier(
            vulkan,
            vulkan->command_buffer,
            core_image,
            core_layout,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
                | VK_ACCESS_SHADER_WRITE_BIT,
            VK_ACCESS_TRANSFER_READ_BIT);

        VkImageBlit blit;
        memset(&blit, 0, sizeof(blit));
        blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        blit.srcSubresource.layerCount = 1;
        blit.srcOffsets[1].x = (int32_t)width;
        blit.srcOffsets[1].y = (int32_t)height;
        blit.srcOffsets[1].z = 1;
        blit.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        blit.dstSubresource.layerCount = 1;
        VkFilter filter;
        rv_destination_rect(
            width,
            height,
            aspect_ratio,
            vulkan->swapchain_extent.width,
            vulkan->swapchain_extent.height,
            &blit.dstOffsets[0],
            &blit.dstOffsets[1],
            &filter);
        vulkan->api.CmdBlitImage(
            vulkan->command_buffer,
            core_image,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            swapchain_image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &blit,
            filter);

        rv_image_barrier(
            vulkan,
            vulkan->command_buffer,
            core_image,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            core_layout,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT,
            VK_ACCESS_TRANSFER_READ_BIT,
            VK_ACCESS_SHADER_READ_BIT
                | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT);
    }

    rv_image_barrier(
        vulkan,
        vulkan->command_buffer,
        swapchain_image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        0);

    result = vulkan->api.EndCommandBuffer(vulkan->command_buffer);
    if (result != VK_SUCCESS) {
        rv_error(
            error,
            error_size,
            "vkEndCommandBuffer failed (VkResult %d).",
            (int)result);
        return false;
    }
    return true;
}

bool rv_vulkan_begin_frame(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    if (vulkan == NULL || !vulkan->started)
        return false;

    vulkan->frame_acquired = false;

    if (atomic_load(&vulkan->drawable_width) == 0
        || atomic_load(&vulkan->drawable_height) == 0) {
        return true;
    }

    if (atomic_load(&vulkan->need_recreate)) {
        pthread_mutex_lock(&vulkan->queue_lock);
        vulkan->api.DeviceWaitIdle(vulkan->device);
        rv_destroy_swapchain(vulkan);
        const bool recreated = rv_create_swapchain(
            vulkan,
            error,
            error_size);
        pthread_mutex_unlock(&vulkan->queue_lock);
        if (!recreated)
            return false;
    }

    if (vulkan->swapchain == VK_NULL_HANDLE) {
        if (!rv_create_swapchain(vulkan, error, error_size))
            return false;
        if (vulkan->swapchain == VK_NULL_HANDLE)
            return true;
    }

    uint32_t image_index = 0;
    VkResult result = vulkan->api.AcquireNextImageKHR(
        vulkan->device,
        vulkan->swapchain,
        RV_ACQUIRE_TIMEOUT_NS,
        vulkan->acquire_semaphore,
        VK_NULL_HANDLE,
        &image_index);
    if (result == VK_TIMEOUT || result == VK_ERROR_OUT_OF_DATE_KHR) {
        /* A hidden or resized drawable can stall the acquire fence on
         * MoltenVK. Drop this frame and rebuild the swapchain next time. */
        atomic_store(&vulkan->need_recreate, true);
        return true;
    }
    /* VK_SUBOPTIMAL_KHR still hands back a usable image. Rebuilding on it
     * would recreate the swapchain every frame on a hidden or unfocused
     * layer; a real resize already arrives through set_drawable_size. */
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
        rv_error(
            error,
            error_size,
            "vkAcquireNextImageKHR failed (VkResult %d).",
            (int)result);
        return false;
    }

    atomic_store(&vulkan->current_index, image_index);
    vulkan->frame_acquired = true;
    return true;
}

bool rv_vulkan_present(
    rv_vulkan *vulkan,
    uint32_t width,
    uint32_t height,
    float aspect_ratio,
    char *error,
    size_t error_size)
{
    if (vulkan == NULL || !vulkan->started)
        return false;

    if (!vulkan->frame_acquired)
        return true;
    const uint32_t image_index = atomic_load(&vulkan->current_index);
    vulkan->frame_acquired = false;

    bool has_image;
    VkImage core_image;
    VkImageLayout core_layout;
    VkSemaphore core_semaphores[RV_MAX_WAIT_SEMAPHORES];
    uint32_t core_semaphore_count;
    VkSemaphore signal_semaphore;
    VkCommandBuffer core_command_buffers[RV_MAX_CORE_COMMAND_BUFFERS];
    uint32_t core_command_buffer_count;

    pthread_mutex_lock(&vulkan->image_lock);
    has_image = vulkan->has_image;
    core_image = vulkan->image_handle;
    core_layout = vulkan->image_layout;
    core_semaphore_count = vulkan->wait_semaphore_count;
    if (core_semaphore_count > 0) {
        memcpy(
            core_semaphores,
            vulkan->wait_semaphores,
            sizeof(VkSemaphore) * core_semaphore_count);
    }
    signal_semaphore = vulkan->signal_semaphore;
    core_command_buffer_count = vulkan->core_command_buffer_count;
    if (core_command_buffer_count > 0) {
        memcpy(
            core_command_buffers,
            vulkan->core_command_buffers,
            sizeof(VkCommandBuffer) * core_command_buffer_count);
    }
    vulkan->wait_semaphore_count = 0;
    vulkan->signal_semaphore = VK_NULL_HANDLE;
    vulkan->core_command_buffer_count = 0;
    pthread_mutex_unlock(&vulkan->image_lock);

    VkResult result = VK_SUCCESS;
    vulkan->api.WaitForFences(
        vulkan->device,
        1,
        &vulkan->fence,
        VK_TRUE,
        RV_FENCE_TIMEOUT_NS);
    vulkan->api.ResetFences(
        vulkan->device,
        1,
        &vulkan->fence);

    if (!rv_record(
            vulkan,
            image_index,
            has_image,
            core_image,
            core_layout,
            width,
            height,
            aspect_ratio,
            error,
            error_size)) {
        return false;
    }

    VkSemaphore wait_semaphores[RV_MAX_WAIT_SEMAPHORES + 1];
    VkPipelineStageFlags wait_stages[RV_MAX_WAIT_SEMAPHORES + 1];
    uint32_t wait_count = 0;
    wait_semaphores[wait_count] = vulkan->acquire_semaphore;
    wait_stages[wait_count] = VK_PIPELINE_STAGE_TRANSFER_BIT;
    wait_count++;
    for (uint32_t index = 0;
         index < core_semaphore_count;
         index++) {
        wait_semaphores[wait_count] = core_semaphores[index];
        wait_stages[wait_count] = VK_PIPELINE_STAGE_TRANSFER_BIT;
        wait_count++;
    }

    VkCommandBuffer command_buffers[RV_MAX_CORE_COMMAND_BUFFERS + 1];
    uint32_t command_buffer_count = 0;
    for (uint32_t index = 0;
         index < core_command_buffer_count;
         index++) {
        command_buffers[command_buffer_count++] =
            core_command_buffers[index];
    }
    command_buffers[command_buffer_count++] = vulkan->command_buffer;

    VkSemaphore signal_semaphores[2];
    uint32_t signal_count = 0;
    signal_semaphores[signal_count++] = vulkan->render_semaphore;
    if (signal_semaphore != VK_NULL_HANDLE) {
        signal_semaphores[signal_count++] = signal_semaphore;
    }

    VkSubmitInfo submit_info;
    memset(&submit_info, 0, sizeof(submit_info));
    submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.waitSemaphoreCount = wait_count;
    submit_info.pWaitSemaphores = wait_semaphores;
    submit_info.pWaitDstStageMask = wait_stages;
    submit_info.commandBufferCount = command_buffer_count;
    submit_info.pCommandBuffers = command_buffers;
    submit_info.signalSemaphoreCount = signal_count;
    submit_info.pSignalSemaphores = signal_semaphores;

    pthread_mutex_lock(&vulkan->queue_lock);
    result = vulkan->api.QueueSubmit(
        vulkan->queue,
        1,
        &submit_info,
        vulkan->fence);
    if (result != VK_SUCCESS) {
        pthread_mutex_unlock(&vulkan->queue_lock);
        rv_error(
            error,
            error_size,
            "vkQueueSubmit failed (VkResult %d).",
            (int)result);
        return false;
    }

    VkPresentInfoKHR present_info;
    memset(&present_info, 0, sizeof(present_info));
    present_info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = &vulkan->render_semaphore;
    present_info.swapchainCount = 1;
    present_info.pSwapchains = &vulkan->swapchain;
    present_info.pImageIndices = &image_index;
    result = vulkan->api.QueuePresentKHR(
        vulkan->present_queue,
        &present_info);
    pthread_mutex_unlock(&vulkan->queue_lock);

    if (result == VK_ERROR_OUT_OF_DATE_KHR) {
        atomic_store(&vulkan->need_recreate, true);
    } else if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
        rv_error(
            error,
            error_size,
            "vkQueuePresentKHR failed (VkResult %d).",
            (int)result);
        return false;
    }

    /* Do not wait for the blit fence here. The next present waits it before
     * reusing the command buffer, and cores that call wait_sync_index get the
     * same fence. Blocking the emulation thread on the GPU here serialised
     * every frame and starved audio. */

    return true;
}

rv_vulkan *rv_vulkan_create(
    const char *library_path,
    void *metal_layer,
    rv_vulkan_layer_format_fn layer_format,
    void *layer_format_context,
    char *error,
    size_t error_size)
{
    if (library_path == NULL || metal_layer == NULL) {
        rv_error(error, error_size, "MoltenVK path or Metal layer is missing.");
        return NULL;
    }

    rv_vulkan *vulkan = calloc(1, sizeof(*vulkan));
    if (vulkan == NULL) {
        rv_error(error, error_size, "Out of memory creating the Vulkan context.");
        return NULL;
    }

    pthread_mutex_init(&vulkan->queue_lock, NULL);
    pthread_mutex_init(&vulkan->image_lock, NULL);
    vulkan->metal_layer = metal_layer;
    vulkan->layer_format = layer_format;
    vulkan->layer_format_context = layer_format_context;
    atomic_store(&vulkan->swapchain_srgb, -1);

    if (rv_moltenvk == NULL
        || strcmp(rv_moltenvk_path, library_path) != 0) {
        void *library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
        if (library == NULL) {
            rv_error(
                error,
                error_size,
                "Could not load MoltenVK: %s",
                dlerror());
            free(vulkan);
            return NULL;
        }
        rv_moltenvk = library;
        strncpy(
            rv_moltenvk_path,
            library_path,
            sizeof(rv_moltenvk_path) - 1);
        rv_moltenvk_path[sizeof(rv_moltenvk_path) - 1] = '\0';
    }
    vulkan->library = rv_moltenvk;

    if (!rv_load_global_functions(vulkan, error, error_size)) {
        dlclose(vulkan->library);
        free(vulkan);
        return NULL;
    }
    return vulkan;
}

void rv_vulkan_set_negotiation(
    rv_vulkan *vulkan,
    const void *interface)
{
    if (vulkan == NULL)
        return;
    vulkan->negotiation =
        (const struct retro_hw_render_context_negotiation_interface_vulkan *)
            interface;
}

bool rv_vulkan_start(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size)
{
    if (vulkan == NULL)
        return false;
    if (vulkan->started)
        return true;

    if (!rv_create_instance(vulkan, error, error_size))
        return false;
    if (!rv_create_surface(vulkan, error, error_size))
        return false;
    if (!rv_pick_physical_device(vulkan, error, error_size))
        return false;
    if (!rv_create_device(vulkan, error, error_size))
        return false;

    RV_LOAD_DEVICE(vulkan, DestroyDevice);
    RV_LOAD_DEVICE(vulkan, DeviceWaitIdle);
    RV_LOAD_DEVICE(vulkan, CreateCommandPool);
    RV_LOAD_DEVICE(vulkan, DestroyCommandPool);
    RV_LOAD_DEVICE(vulkan, AllocateCommandBuffers);
    RV_LOAD_DEVICE(vulkan, BeginCommandBuffer);
    RV_LOAD_DEVICE(vulkan, EndCommandBuffer);
    RV_LOAD_DEVICE(vulkan, CmdPipelineBarrier);
    RV_LOAD_DEVICE(vulkan, CmdClearColorImage);
    RV_LOAD_DEVICE(vulkan, CmdBlitImage);
    RV_LOAD_DEVICE(vulkan, CreateSemaphore);
    RV_LOAD_DEVICE(vulkan, DestroySemaphore);
    RV_LOAD_DEVICE(vulkan, CreateFence);
    RV_LOAD_DEVICE(vulkan, DestroyFence);
    RV_LOAD_DEVICE(vulkan, WaitForFences);
    RV_LOAD_DEVICE(vulkan, ResetFences);
    RV_LOAD_DEVICE(vulkan, QueueSubmit);

    if (!rv_create_commands_and_sync(vulkan, error, error_size))
        return false;

    rv_fill_interface(vulkan);
    vulkan->started = true;

    if (!rv_create_swapchain(vulkan, error, error_size)) {
        /* A layer that is not in a window yet is normal during startup. Keep
         * the context alive; the first present retries with the real size. */
        rv_log("deferring the swapchain: %s", error);
        if (error != NULL && error_size > 0)
            error[0] = '\0';
        atomic_store(&vulkan->need_recreate, true);
    }
    return true;
}

void *rv_vulkan_interface(rv_vulkan *vulkan)
{
    if (vulkan == NULL || !vulkan->started)
        return NULL;
    return &vulkan->interface;
}

void rv_vulkan_set_drawable_size(
    rv_vulkan *vulkan,
    uint32_t width,
    uint32_t height)
{
    if (vulkan == NULL)
        return;
    const uint32_t old_width = atomic_exchange(&vulkan->drawable_width, width);
    const uint32_t old_height = atomic_exchange(&vulkan->drawable_height, height);
    if (old_width != width || old_height != height) {
        atomic_store(&vulkan->need_recreate, true);
    }
}

void rv_vulkan_destroy(rv_vulkan *vulkan)
{
    if (vulkan == NULL)
        return;

    if (vulkan->device != VK_NULL_HANDLE) {
        if (vulkan->api.DeviceWaitIdle != NULL)
            vulkan->api.DeviceWaitIdle(vulkan->device);
        if (vulkan->api.DestroySwapchainKHR != NULL)
            rv_destroy_swapchain(vulkan);
        if (vulkan->fence != VK_NULL_HANDLE
            && vulkan->api.DestroyFence != NULL)
            vulkan->api.DestroyFence(
                vulkan->device,
                vulkan->fence,
                NULL);
        if (vulkan->acquire_semaphore != VK_NULL_HANDLE
            && vulkan->api.DestroySemaphore != NULL)
            vulkan->api.DestroySemaphore(
                vulkan->device,
                vulkan->acquire_semaphore,
                NULL);
        if (vulkan->render_semaphore != VK_NULL_HANDLE
            && vulkan->api.DestroySemaphore != NULL)
            vulkan->api.DestroySemaphore(
                vulkan->device,
                vulkan->render_semaphore,
                NULL);
        if (vulkan->command_pool != VK_NULL_HANDLE
            && vulkan->api.DestroyCommandPool != NULL)
            vulkan->api.DestroyCommandPool(
                vulkan->device,
                vulkan->command_pool,
                NULL);
        if (vulkan->negotiation != NULL
            && vulkan->negotiation->destroy_device != NULL) {
            vulkan->negotiation->destroy_device();
        }
        if (vulkan->api.DestroyDevice != NULL)
            vulkan->api.DestroyDevice(vulkan->device, NULL);
        vulkan->device = VK_NULL_HANDLE;
    }

    if (vulkan->surface != VK_NULL_HANDLE)
        vulkan->api.DestroySurfaceKHR(
            vulkan->instance,
            vulkan->surface,
            NULL);
    if (vulkan->instance != VK_NULL_HANDLE)
        vulkan->api.DestroyInstance(vulkan->instance, NULL);

    pthread_mutex_destroy(&vulkan->image_lock);
    pthread_mutex_destroy(&vulkan->queue_lock);
    /* Deliberately not dlclose()d; see rv_moltenvk. */
    free(vulkan);
}

/*
 * ABI probes for the Swift tests. The Swift side mirrors only
 * retro_hw_render_callback; everything else stays owned by this file.
 */
size_t rv_abi_hw_render_callback_size(void)
{
    return sizeof(struct retro_hw_render_callback);
}

size_t rv_abi_hw_render_callback_context_type_offset(void)
{
    return offsetof(struct retro_hw_render_callback, context_type);
}

size_t rv_abi_hw_render_callback_context_reset_offset(void)
{
    return offsetof(struct retro_hw_render_callback, context_reset);
}

size_t rv_abi_hw_render_callback_get_current_framebuffer_offset(void)
{
    return offsetof(
        struct retro_hw_render_callback,
        get_current_framebuffer);
}

size_t rv_abi_hw_render_callback_get_proc_address_offset(void)
{
    return offsetof(struct retro_hw_render_callback, get_proc_address);
}

size_t rv_abi_hw_render_callback_depth_offset(void)
{
    return offsetof(struct retro_hw_render_callback, depth);
}

size_t rv_abi_hw_render_callback_version_major_offset(void)
{
    return offsetof(struct retro_hw_render_callback, version_major);
}

size_t rv_abi_hw_render_callback_cache_context_offset(void)
{
    return offsetof(struct retro_hw_render_callback, cache_context);
}

size_t rv_abi_hw_render_callback_context_destroy_offset(void)
{
    return offsetof(struct retro_hw_render_callback, context_destroy);
}

size_t rv_abi_hw_render_callback_debug_context_offset(void)
{
    return offsetof(struct retro_hw_render_callback, debug_context);
}

size_t rv_abi_vulkan_context_value(void)
{
    return RETRO_HW_CONTEXT_VULKAN;
}

size_t rv_abi_vulkan_interface_version(void)
{
    return RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
}
