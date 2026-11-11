// SPDX-License-Identifier: MIT
//
// A content-free Libretro core that exercises the frontend's Vulkan path:
// it asks for RETRO_HW_CONTEXT_VULKAN, renders a cycling colour into its own
// VkImage, and hands it over with set_image. It is the Vulkan counterpart to
// the 2048 pipeline test and needs no ROM, BIOS, or firmware.

#define VK_NO_PROTOTYPES
#include <libretro/libretro.h>
#include <libretro/libretro_vulkan.h>
#include <vulkan/vulkan.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define FRAME_WIDTH 640
#define FRAME_HEIGHT 480
#define SAMPLE_RATE 48000
#define MAX_FRAMES 8

static retro_environment_t environment_callback;
static retro_video_refresh_t video_callback;
static retro_audio_sample_t audio_sample_callback;
static retro_audio_sample_batch_t audio_batch_callback;
static retro_input_poll_t input_poll_callback;
static retro_input_state_t input_state_callback;

static struct retro_hw_render_interface_vulkan *vulkan;
static bool context_ready;

static VkImage image;
static VkDeviceMemory image_memory;
static VkImageView image_view;
static VkCommandPool command_pool;
static VkCommandBuffer command_buffer;
static VkFence fence;
static VkImageLayout image_layout = VK_IMAGE_LAYOUT_UNDEFINED;

static PFN_vkGetPhysicalDeviceMemoryProperties pGetPhysicalDeviceMemoryProperties;
static PFN_vkCreateImage pCreateImage;
static PFN_vkDestroyImage pDestroyImage;
static PFN_vkGetImageMemoryRequirements pGetImageMemoryRequirements;
static PFN_vkAllocateMemory pAllocateMemory;
static PFN_vkFreeMemory pFreeMemory;
static PFN_vkBindImageMemory pBindImageMemory;
static PFN_vkCreateImageView pCreateImageView;
static PFN_vkDestroyImageView pDestroyImageView;
static PFN_vkCreateCommandPool pCreateCommandPool;
static PFN_vkDestroyCommandPool pDestroyCommandPool;
static PFN_vkAllocateCommandBuffers pAllocateCommandBuffers;
static PFN_vkFreeCommandBuffers pFreeCommandBuffers;
static PFN_vkBeginCommandBuffer pBeginCommandBuffer;
static PFN_vkEndCommandBuffer pEndCommandBuffer;
static PFN_vkCmdPipelineBarrier pCmdPipelineBarrier;
static PFN_vkCmdClearColorImage pCmdClearColorImage;
static PFN_vkCreateFence pCreateFence;
static PFN_vkDestroyFence pDestroyFence;
static PFN_vkWaitForFences pWaitForFences;
static PFN_vkResetFences pResetFences;
static PFN_vkQueueSubmit pQueueSubmit;

static uint64_t frame_counter;

#define LOAD_DEVICE(name)                                                     \
    do {                                                                      \
        p##name = (PFN_vk##name)vulkan->get_device_proc_addr(                   \
            vulkan->device,                                                   \
            "vk" #name);                                                           \
        if (p##name == NULL) {                                                \
            fprintf(stderr, "[vulkan-test] missing %s\n", #name);             \
            return;                                                           \
        }                                                                     \
    } while (0)

static void destroy_resources(void)
{
    if (vulkan == NULL)
        return;

    if (fence != VK_NULL_HANDLE) {
        pDestroyFence(vulkan->device, fence, NULL);
        fence = VK_NULL_HANDLE;
    }
    if (command_pool != VK_NULL_HANDLE) {
        pDestroyCommandPool(vulkan->device, command_pool, NULL);
        command_pool = VK_NULL_HANDLE;
        command_buffer = VK_NULL_HANDLE;
    }
    if (image_view != VK_NULL_HANDLE) {
        pDestroyImageView(vulkan->device, image_view, NULL);
        image_view = VK_NULL_HANDLE;
    }
    if (image != VK_NULL_HANDLE) {
        pDestroyImage(vulkan->device, image, NULL);
        image = VK_NULL_HANDLE;
    }
    if (image_memory != VK_NULL_HANDLE) {
        pFreeMemory(vulkan->device, image_memory, NULL);
        image_memory = VK_NULL_HANDLE;
    }
    image_layout = VK_IMAGE_LAYOUT_UNDEFINED;
}

static VkResult create_image(void)
{
    VkImageCreateInfo create_info;
    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    create_info.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
    create_info.imageType = VK_IMAGE_TYPE_2D;
    create_info.format = VK_FORMAT_B8G8R8A8_UNORM;
    create_info.extent.width = FRAME_WIDTH;
    create_info.extent.height = FRAME_HEIGHT;
    create_info.extent.depth = 1;
    create_info.mipLevels = 1;
    create_info.arrayLayers = 1;
    create_info.samples = VK_SAMPLE_COUNT_1_BIT;
    create_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    create_info.usage =
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
        | VK_IMAGE_USAGE_TRANSFER_DST_BIT
        | VK_IMAGE_USAGE_TRANSFER_SRC_BIT
        | VK_IMAGE_USAGE_SAMPLED_BIT;
    create_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    create_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    VkResult result = pCreateImage(
        vulkan->device,
        &create_info,
        NULL,
        &image);
    if (result != VK_SUCCESS)
        return result;

    VkMemoryRequirements requirements;
    pGetImageMemoryRequirements(vulkan->device, image, &requirements);

    VkPhysicalDeviceMemoryProperties memory_properties;
    pGetPhysicalDeviceMemoryProperties(
        vulkan->gpu,
        &memory_properties);

    uint32_t memory_type = UINT32_MAX;
    for (uint32_t index = 0;
         index < memory_properties.memoryTypeCount;
         index++) {
        if ((requirements.memoryTypeBits & (1u << index)) == 0)
            continue;
        if ((memory_properties.memoryTypes[index].propertyFlags
             & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
            == 0)
            continue;
        memory_type = index;
        break;
    }
    if (memory_type == UINT32_MAX)
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;

    VkMemoryAllocateInfo allocate_info;
    memset(&allocate_info, 0, sizeof(allocate_info));
    allocate_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocate_info.allocationSize = requirements.size;
    allocate_info.memoryTypeIndex = memory_type;
    result = pAllocateMemory(
        vulkan->device,
        &allocate_info,
        NULL,
        &image_memory);
    if (result != VK_SUCCESS)
        return result;

    result = pBindImageMemory(
        vulkan->device,
        image,
        image_memory,
        0);
    if (result != VK_SUCCESS)
        return result;

    VkImageViewCreateInfo view_info;
    memset(&view_info, 0, sizeof(view_info));
    view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image;
    view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = VK_FORMAT_B8G8R8A8_UNORM;
    view_info.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
    view_info.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
    view_info.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
    view_info.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
    view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.layerCount = 1;
    return pCreateImageView(
        vulkan->device,
        &view_info,
        NULL,
        &image_view);
}

static void context_reset(void)
{
    struct retro_hw_render_interface *base = NULL;
    if (!environment_callback(
            RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE,
            &base)
        || base == NULL) {
        fprintf(stderr, "[vulkan-test] no hardware render interface\n");
        return;
    }
    if (base->interface_type != RETRO_HW_RENDER_INTERFACE_VULKAN) {
        fprintf(stderr, "[vulkan-test] wrong interface type\n");
        return;
    }
    if (base->interface_version !=
        RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION) {
        fprintf(stderr,
                "[vulkan-test] interface version %u, expected %u\n",
                base->interface_version,
                RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION);
        return;
    }
    vulkan = (struct retro_hw_render_interface_vulkan *)base;

    pGetPhysicalDeviceMemoryProperties =
        (PFN_vkGetPhysicalDeviceMemoryProperties)
            vulkan->get_instance_proc_addr(
                vulkan->instance,
                "vkGetPhysicalDeviceMemoryProperties");
    if (pGetPhysicalDeviceMemoryProperties == NULL) {
        fprintf(stderr, "[vulkan-test] no memory properties\n");
        return;
    }
    LOAD_DEVICE(CreateImage);
    LOAD_DEVICE(DestroyImage);
    LOAD_DEVICE(GetImageMemoryRequirements);
    LOAD_DEVICE(AllocateMemory);
    LOAD_DEVICE(FreeMemory);
    LOAD_DEVICE(BindImageMemory);
    LOAD_DEVICE(CreateImageView);
    LOAD_DEVICE(DestroyImageView);
    LOAD_DEVICE(CreateCommandPool);
    LOAD_DEVICE(DestroyCommandPool);
    LOAD_DEVICE(AllocateCommandBuffers);
    LOAD_DEVICE(FreeCommandBuffers);
    LOAD_DEVICE(BeginCommandBuffer);
    LOAD_DEVICE(EndCommandBuffer);
    LOAD_DEVICE(CmdPipelineBarrier);
    LOAD_DEVICE(CmdClearColorImage);
    LOAD_DEVICE(CreateFence);
    LOAD_DEVICE(DestroyFence);
    LOAD_DEVICE(WaitForFences);
    LOAD_DEVICE(ResetFences);
    LOAD_DEVICE(QueueSubmit);

    VkResult result = create_image();
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[vulkan-test] create image failed: %d\n", result);
        return;
    }

    VkCommandPoolCreateInfo pool_info;
    memset(&pool_info, 0, sizeof(pool_info));
    pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = vulkan->queue_index;
    result = pCreateCommandPool(
        vulkan->device,
        &pool_info,
        NULL,
        &command_pool);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[vulkan-test] command pool failed: %d\n", result);
        return;
    }

    VkCommandBufferAllocateInfo allocate_info;
    memset(&allocate_info, 0, sizeof(allocate_info));
    allocate_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocate_info.commandPool = command_pool;
    allocate_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate_info.commandBufferCount = 1;
    result = pAllocateCommandBuffers(
        vulkan->device,
        &allocate_info,
        &command_buffer);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[vulkan-test] command buffer failed: %d\n", result);
        return;
    }

    VkFenceCreateInfo fence_info;
    memset(&fence_info, 0, sizeof(fence_info));
    fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    result = pCreateFence(
        vulkan->device,
        &fence_info,
        NULL,
        &fence);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[vulkan-test] fence failed: %d\n", result);
        return;
    }

    frame_counter = 0;
    context_ready = true;
    fprintf(stderr, "[vulkan-test] context ready\n");
}

static void context_destroy(void)
{
    context_ready = false;
    destroy_resources();
    vulkan = NULL;
}

static void image_barrier(
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
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcAccessMask = source_access;
    barrier.dstAccessMask = destination_access;
    pCmdPipelineBarrier(
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

static void render_frame(void)
{
    if (vulkan == NULL || !context_ready)
        return;

    const bool pressed = input_state_callback(
        0,
        RETRO_DEVICE_JOYPAD,
        0,
        RETRO_DEVICE_ID_JOYPAD_A)
        != 0;

    VkClearColorValue color;
    memset(&color, 0, sizeof(color));
    if (pressed) {
        color.float32[0] = 0.0f;
        color.float32[1] = 0.85f;
        color.float32[2] = 0.2f;
        color.float32[3] = 1.0f;
    } else {
        const float phase = (float)(frame_counter % 180) / 180.0f;
        color.float32[0] = 0.15f + 0.35f * phase;
        color.float32[1] = 0.20f;
        color.float32[2] = 0.75f - 0.35f * phase;
        color.float32[3] = 1.0f;
    }

    VkCommandBufferBeginInfo begin_info;
    memset(&begin_info, 0, sizeof(begin_info));
    begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (pBeginCommandBuffer(command_buffer, &begin_info) != VK_SUCCESS)
        return;

    image_barrier(
        image_layout,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_ACCESS_SHADER_READ_BIT,
        VK_ACCESS_TRANSFER_WRITE_BIT);

    VkImageSubresourceRange range;
    memset(&range, 0, sizeof(range));
    range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    range.levelCount = 1;
    range.layerCount = 1;
    pCmdClearColorImage(
        command_buffer,
        image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        &color,
        1,
        &range);

    image_barrier(
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_ACCESS_SHADER_READ_BIT);
    image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    if (pEndCommandBuffer(command_buffer) != VK_SUCCESS)
        return;

    VkSubmitInfo submit_info;
    memset(&submit_info, 0, sizeof(submit_info));
    submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &command_buffer;

    vulkan->lock_queue(vulkan->handle);
    const VkResult submitted = pQueueSubmit(
        vulkan->queue,
        1,
        &submit_info,
        fence);
    vulkan->unlock_queue(vulkan->handle);
    if (submitted != VK_SUCCESS) {
        fprintf(stderr, "[vulkan-test] queue submit failed: %d\n", submitted);
        return;
    }

    pWaitForFences(
        vulkan->device,
        1,
        &fence,
        VK_TRUE,
        UINT64_MAX);
    pResetFences(vulkan->device, 1, &fence);

    struct retro_vulkan_image retro_image;
    memset(&retro_image, 0, sizeof(retro_image));
    retro_image.image_view = image_view;
    retro_image.image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    retro_image.create_info.sType =
        VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    retro_image.create_info.image = image;
    retro_image.create_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    retro_image.create_info.format = VK_FORMAT_B8G8R8A8_UNORM;
    retro_image.create_info.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
    retro_image.create_info.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
    retro_image.create_info.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
    retro_image.create_info.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
    retro_image.create_info.subresourceRange.aspectMask =
        VK_IMAGE_ASPECT_COLOR_BIT;
    retro_image.create_info.subresourceRange.levelCount = 1;
    retro_image.create_info.subresourceRange.layerCount = 1;

    vulkan->set_image(
        vulkan->handle,
        &retro_image,
        0,
        NULL,
        vulkan->queue_index);
    video_callback(
        RETRO_HW_FRAME_BUFFER_VALID,
        FRAME_WIDTH,
        FRAME_HEIGHT,
        0);
    frame_counter++;
}

void retro_set_environment(retro_environment_t callback)
{
    environment_callback = callback;
}

void retro_set_video_refresh(retro_video_refresh_t callback)
{
    video_callback = callback;
}

void retro_set_audio_sample(retro_audio_sample_t callback)
{
    audio_sample_callback = callback;
}

void retro_set_audio_sample_batch(retro_audio_sample_batch_t callback)
{
    audio_batch_callback = callback;
}

void retro_set_input_poll(retro_input_poll_t callback)
{
    input_poll_callback = callback;
}

void retro_set_input_state(retro_input_state_t callback)
{
    input_state_callback = callback;
}

void retro_init(void) {}

void retro_deinit(void) {}

unsigned retro_api_version(void)
{
    return RETRO_API_VERSION;
}

void retro_get_system_info(struct retro_system_info *info)
{
    memset(info, 0, sizeof(*info));
    info->library_name = "RetroVault Vulkan Test";
    info->library_version = "1";
    info->valid_extensions = "";
    info->need_fullpath = false;
    info->block_extract = false;
}

void retro_get_system_av_info(struct retro_system_av_info *info)
{
    memset(info, 0, sizeof(*info));
    info->geometry.base_width = FRAME_WIDTH;
    info->geometry.base_height = FRAME_HEIGHT;
    info->geometry.max_width = FRAME_WIDTH;
    info->geometry.max_height = FRAME_HEIGHT;
    info->geometry.aspect_ratio = 4.0f / 3.0f;
    info->timing.fps = 60.0;
    info->timing.sample_rate = SAMPLE_RATE;
}

void retro_set_controller_port_device(unsigned port, unsigned device)
{
    (void)port;
    (void)device;
}

void retro_reset(void)
{
    frame_counter = 0;
}

bool retro_load_game(const struct retro_game_info *game)
{
    (void)game;

    enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
    environment_callback(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);

    struct retro_hw_render_callback hardware;
    memset(&hardware, 0, sizeof(hardware));
    hardware.context_type = RETRO_HW_CONTEXT_VULKAN;
    hardware.version_major = 1;
    hardware.version_minor = 1;
    hardware.context_reset = context_reset;
    hardware.context_destroy = context_destroy;
    hardware.cache_context = true;
    return environment_callback(
        RETRO_ENVIRONMENT_SET_HW_RENDER,
        &hardware);
}

void retro_unload_game(void)
{
    if (vulkan != NULL) {
        vulkan->set_image(
            vulkan->handle,
            NULL,
            0,
            NULL,
            vulkan->queue_index);
        vulkan->wait_sync_index(vulkan->handle);
    }
    context_ready = false;
}

void retro_run(void)
{
    input_poll_callback();
    render_frame();

    static int16_t silence[800 * 2];
    audio_batch_callback(silence, 800);
}

size_t retro_serialize_size(void)
{
    return 0;
}

bool retro_serialize(void *data, size_t size)
{
    (void)data;
    (void)size;
    return false;
}

bool retro_unserialize(const void *data, size_t size)
{
    (void)data;
    (void)size;
    return false;
}

void retro_cheat_reset(void) {}

void retro_cheat_set(unsigned index, bool enabled, const char *code)
{
    (void)index;
    (void)enabled;
    (void)code;
}

bool retro_load_game_special(
    unsigned game_type,
    const struct retro_game_info *info,
    size_t num_info)
{
    (void)game_type;
    (void)info;
    (void)num_info;
    return false;
}

void *retro_get_memory_data(unsigned id)
{
    (void)id;
    return NULL;
}

size_t retro_get_memory_size(unsigned id)
{
    (void)id;
    return 0;
}
