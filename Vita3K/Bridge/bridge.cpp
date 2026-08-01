// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-only

#include <app/functions.h>
#include <app/session_controller.h>
#include "archive.h"
#include <config/functions.h>
#include <ctrl/functions.h>
#include <modules/module_parent.h>
#include <packages/functions.h>
#include <renderer/functions.h>
#include <renderer/frame_host.h>
#include <util/fs.h>
#include <util/log.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_vulkan.h>

#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

std::mutex creation_error_mutex;
std::string creation_error;

void set_creation_error(std::string message) {
    std::lock_guard<std::mutex> lock(creation_error_mutex);
    creation_error = std::move(message);
}

bool load_bundled_moltenvk() {
    Dl_info library_info{};
    if (dladdr(
            reinterpret_cast<const void *>(&load_bundled_moltenvk),
            &library_info)
        == 0
        || !library_info.dli_fname) {
        return false;
    }

    const fs::path moltenvk_path =
        fs::path(library_info.dli_fname).parent_path()
        / "libMoltenVK.dylib";
    return SDL_Vulkan_LoadLibrary(moltenvk_path.string().c_str());
}

class MacFrameHost final : public renderer::FrameHost {
public:
    MacFrameHost(void *view, int width, int height)
        : view_(view), width_(width), height_(height) {
    }

    renderer::DisplayHandle handle() const override {
        return renderer::MacOSDisplayHandle{ view_ };
    }

    int drawable_width() const override {
        return width_.load(std::memory_order_relaxed);
    }

    int drawable_height() const override {
        return height_.load(std::memory_order_relaxed);
    }

    std::vector<std::string> font_dirs() const override {
        return { "/System/Library/Fonts/", "/Library/Fonts/" };
    }

    void resize(int width, int height) {
        width_.store(width, std::memory_order_relaxed);
        height_.store(height, std::memory_order_relaxed);
    }

private:
    void *view_ = nullptr;
    std::atomic<int> width_{ 960 };
    std::atomic<int> height_{ 544 };
};

struct RetroVaultVita3KEngine {
    Root root_paths;
    std::unique_ptr<EmuEnvState> emuenv;
    std::unique_ptr<app::AppSessionController> session;
    std::unique_ptr<MacFrameHost> frame_host;
    std::atomic<bool> stop_requested{ false };
    std::mutex error_mutex;
    std::string last_error;
    std::string installed_title_id;

    void set_error(std::string message) {
        std::lock_guard<std::mutex> lock(error_mutex);
        last_error = std::move(message);
    }
};

bool initialize_engine(
    RetroVaultVita3KEngine &engine,
    const fs::path &storage_path,
    const fs::path &assets_path) {
    std::string stage = "configuring paths";
    try {
        const fs::path vita_path = storage_path / "vita" / "";
        engine.root_paths.set_static_assets_path(assets_path);
        engine.root_paths.set_vita_fs_path(vita_path);
        engine.root_paths.set_log_path(storage_path);
        engine.root_paths.set_config_path(storage_path);
        engine.root_paths.set_shared_path(storage_path);
        engine.root_paths.set_cache_path(storage_path / "cache" / "");
        engine.root_paths.set_patch_path(storage_path / "patch" / "");

        stage = "creating the Vita filesystem";
        fs::create_directories(vita_path);
        stage = "creating the configuration directory";
        fs::create_directories(engine.root_paths.get_config_path());
        stage = "creating the cache directory";
        fs::create_directories(engine.root_paths.get_cache_path());
        stage = "creating shader logs";
        fs::create_directories(engine.root_paths.get_log_path() / "shaderlog");
        stage = "creating texture logs";
        fs::create_directories(engine.root_paths.get_log_path() / "texturelog");
        stage = "creating the patch directory";
        fs::create_directories(engine.root_paths.get_patch_path());
        stage = "creating the texture directory";
        fs::create_directories(engine.root_paths.get_shared_path() / "textures");

        stage = "initializing logging";
        if (logging::init(engine.root_paths, true) != Success) {
            engine.set_error("Vita3K could not initialize its log store.");
            return false;
        }

        stage = "creating the hosted configuration";
        engine.emuenv = std::make_unique<EmuEnvState>();
        Config cfg{};
        cfg.config_path = storage_path;
        cfg.set_vita_fs_path(vita_path);
        cfg.current_config.backend_renderer = "Vulkan";

        stage = "initializing the emulated environment";
        if (!app::init(*engine.emuenv, cfg, engine.root_paths)) {
            engine.set_error("Vita3K could not initialize its emulated environment.");
            return false;
        }

        stage = "enumerating Vulkan devices";
        engine.emuenv->vulkan_device_info =
            std::make_unique<renderer::VulkanDeviceInfo>(
                renderer::enumerate_vulkan_devices());
        if (engine.emuenv->cfg.controller_binds.size() != 15
            || engine.emuenv->cfg.controller_axis_binds.size() != 6) {
            app::reset_controller_binding(*engine.emuenv);
        }

        stage = "loading Vita libraries";
        init_libraries(*engine.emuenv);
        stage = "loading installed applications";
        app::init_apps_list(*engine.emuenv);
        stage = "loading Vita users";
        app::load_users(*engine.emuenv);
        if (!app::ensure_current_user(*engine.emuenv)) {
            engine.set_error("Vita3K could not initialize a Vita user profile.");
            return false;
        }

        engine.session =
            std::make_unique<app::AppSessionController>(*engine.emuenv);
        return true;
    } catch (const std::exception &error) {
        engine.set_error(stage + ": " + error.what());
        return false;
    }
}

} // namespace

extern "C" {

void *retrovault_vita3k_create(
    const char *storage_path,
    const char *assets_path) {
    set_creation_error({});
    if (!storage_path || !assets_path) {
        set_creation_error("RetroVault did not provide Vita3K storage and asset paths.");
        return nullptr;
    }

    SDL_SetMainReady();
    if (!SDL_Init(
            SDL_INIT_AUDIO | SDL_INIT_VIDEO | SDL_INIT_GAMEPAD
            | SDL_INIT_HAPTIC | SDL_INIT_SENSOR)) {
        set_creation_error(std::string("SDL initialization failed: ") + SDL_GetError());
        return nullptr;
    }
    if (!load_bundled_moltenvk()) {
        set_creation_error(std::string("MoltenVK initialization failed: ") + SDL_GetError());
        SDL_Quit();
        return nullptr;
    }

    auto engine = std::make_unique<RetroVaultVita3KEngine>();
    if (!initialize_engine(
            *engine, fs::path(storage_path), fs::path(assets_path))) {
        set_creation_error(engine->last_error);
        SDL_Vulkan_UnloadLibrary();
        SDL_Quit();
        return nullptr;
    }
    return engine.release();
}

const char *retrovault_vita3k_creation_error() {
    std::lock_guard<std::mutex> lock(creation_error_mutex);
    return creation_error.c_str();
}

void retrovault_vita3k_destroy(void *opaque_engine) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (!engine)
        return;
    if (engine->session && engine->session->has_active_session())
        engine->session->stop(app::AppSessionStopReason::FrontendShutdown);
    delete engine;
    SDL_Vulkan_UnloadLibrary();
    SDL_Quit();
}

int retrovault_vita3k_firmware_mask(void *opaque_engine) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (!engine || !engine->emuenv)
        return 0;
    const auto state = app::get_firmware_state(*engine->emuenv);
    return (state.preinstalled_package ? 1 : 0)
        | (state.main_firmware ? 2 : 0)
        | (state.font_package ? 4 : 0);
}

int retrovault_vita3k_install_firmware(
    void *opaque_engine,
    const char *firmware_path) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (!engine || !engine->emuenv || !firmware_path)
        return 0;

    const std::string version = install_pup(
        engine->emuenv->vita_fs_path,
        fs::path(firmware_path),
        [](uint32_t) {});
    if (version.empty()) {
        engine->set_error("Vita3K could not install this Vita firmware package.");
        return 0;
    }
    app::scan_apps(*engine->emuenv);
    return 1;
}

int retrovault_vita3k_install_archive(
    void *opaque_engine,
    const char *archive_path) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (!engine || !engine->emuenv || !archive_path)
        return 0;

    const auto progress = [](ArchiveContents) {};
    const auto reinstall = [](const std::string &, const std::string &) {
        return true;
    };
    const auto installed = install_archive(
        *engine->emuenv, fs::path(archive_path), progress, reinstall);
    const auto playable = std::find_if(
        installed.begin(), installed.end(), [](const ContentInfo &content) {
            return content.state && !content.title_id.empty();
        });
    if (playable == installed.end()) {
        engine->set_error("Vita3K could not install this Vita archive.");
        return 0;
    }
    engine->installed_title_id = playable->title_id;
    app::scan_apps(*engine->emuenv);
    return 1;
}

const char *retrovault_vita3k_installed_title_id(void *opaque_engine) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    return engine ? engine->installed_title_id.c_str() : "";
}

int retrovault_vita3k_run(
    void *opaque_engine,
    void *view,
    int width,
    int height,
    const char *title_id) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (!engine || !engine->emuenv || !engine->session || !view || !title_id)
        return 0;

    engine->stop_requested.store(false, std::memory_order_release);
    engine->frame_host = std::make_unique<MacFrameHost>(
        view, width, height);
    refresh_controllers(engine->emuenv->ctrl, *engine->emuenv);

    AppLaunchRequest request{ .app_path = title_id };
    if (!engine->session->begin_launch(request)
        || !engine->session->initialize_renderer(*engine->frame_host)
        || !engine->session->initialize_runtime()
        || !engine->session->load_and_run()) {
        engine->set_error(
            "Vita3K could not start the installed Vita title.");
        engine->session->stop(app::AppSessionStopReason::LaunchFailure);
        return 0;
    }

    app::LaunchRuntimeMetrics metrics{};
    while (!engine->stop_requested.load(std::memory_order_acquire)
        && engine->session->is_running()) {
        SDL_Event event{};
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_GAMEPAD_ADDED
                || event.type == SDL_EVENT_GAMEPAD_REMOVED)
                refresh_controllers(engine->emuenv->ctrl, *engine->emuenv);
        }
        app::update_runtime_metrics(*engine->emuenv, metrics);
        SDL_Delay(8);
    }

    engine->session->stop(app::AppSessionStopReason::UserRequest);
    engine->frame_host.reset();
    return 1;
}

void retrovault_vita3k_resize(
    void *opaque_engine,
    int width,
    int height) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (engine && engine->frame_host)
        engine->frame_host->resize(width, height);
}

void retrovault_vita3k_stop(void *opaque_engine) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (engine)
        engine->stop_requested.store(true, std::memory_order_release);
}

const char *retrovault_vita3k_last_error(void *opaque_engine) {
    auto *engine = static_cast<RetroVaultVita3KEngine *>(opaque_engine);
    if (!engine)
        return "Vita3K is unavailable.";
    std::lock_guard<std::mutex> lock(engine->error_mutex);
    return engine->last_error.c_str();
}

} // extern "C"
