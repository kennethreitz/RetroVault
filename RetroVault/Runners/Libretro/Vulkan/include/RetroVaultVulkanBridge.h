/*
 * RetroVault Vulkan frontend bridge.
 *
 * Owns the Vulkan instance, surface, device, swapchain, and presentation for
 * one Libretro hardware-render session. Swift keeps the core and the player
 * view; this file implements the Libretro `retro_hw_render_interface_vulkan`
 * callbacks and presents the core's image with vkCmdBlitImage.
 *
 * The bridge is deliberately C: the Libretro and Vulkan ABI structs are
 * compiled from their upstream headers rather than mirrored in Swift.
 */

#ifndef RETROVAULT_VULKAN_BRIDGE_H
#define RETROVAULT_VULKAN_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rv_vulkan rv_vulkan;

/*
 * Called before the swapchain is created so the caller can match the
 * CAMetalLayer's pixel format to the core image. `srgb` is true for an sRGB
 * core image.
 */
typedef void (*rv_vulkan_layer_format_fn)(void *context, bool srgb);

/*
 * `library_path` is the absolute path of libMoltenVK.dylib.
 * `metal_layer` is a CAMetalLayer.
 * Returns NULL on failure and writes a message into `error`.
 */
rv_vulkan *rv_vulkan_create(
    const char *library_path,
    void *metal_layer,
    rv_vulkan_layer_format_fn layer_format,
    void *layer_format_context,
    char *error,
    size_t error_size);

/* Stores the core's context-negotiation interface (v1 or v2). */
void rv_vulkan_set_negotiation(rv_vulkan *vulkan, const void *interface);

/*
 * Creates the instance, surface, device, and the Libretro interface. Must run
 * after retro_load_game has returned, so the negotiation interface is known.
 */
bool rv_vulkan_start(rv_vulkan *vulkan, char *error, size_t error_size);

/* The `retro_hw_render_interface_vulkan *` handed to the core. */
void *rv_vulkan_interface(rv_vulkan *vulkan);

/* Drawable size in pixels, updated by the view on resize and backscale. */
void rv_vulkan_set_drawable_size(
    rv_vulkan *vulkan,
    uint32_t width,
    uint32_t height);

/*
 * Acquires the swapchain image for this retro_run and publishes its index to
 * get_sync_index. Call once before the core runs. Safe to call when the
 * drawable has no size; the frame is then dropped.
 */
bool rv_vulkan_begin_frame(
    rv_vulkan *vulkan,
    char *error,
    size_t error_size);

/*
 * Presents the image most recently handed to set_image. Called from the
 * Libretro video callback. `aspect_ratio` of 0 uses the frame's own shape.
 */
bool rv_vulkan_present(
    rv_vulkan *vulkan,
    uint32_t width,
    uint32_t height,
    float aspect_ratio,
    char *error,
    size_t error_size);

void rv_vulkan_destroy(rv_vulkan *vulkan);

#ifdef __cplusplus
}
#endif

#endif
