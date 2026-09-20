/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/
#include "SDL_internal.h"

#ifdef SDL_VIDEO_DRIVER_OPENHARMONY

// HarmonyOS/OpenHarmony SDL video driver implementation

#include <window_manager/oh_display_manager.h>

// !!! FIXME: these are defined as "const uint32_t VARNAME = VALUE;" in native_interface_xcomponent.h, which becomes a global variable in _our_ C code! Maybe C++ handles this differently...?
#define OH_XCOMPONENT_ID_LEN_MAX sdl_ohosvideo_OH_XCOMPONENT_ID_LEN_MAX
#define OH_MAX_TOUCH_POINTS_NUMBER sdl_ohosvideo_OH_MAX_TOUCH_POINTS_NUMBER
#include <ace/xcomponent/native_interface_xcomponent.h>

// !!! FIXME: move stuff in from Android code

#include "../SDL_sysvideo.h"
#include "../SDL_pixels_c.h"
#include "../../events/SDL_events_c.h"
#include "../../events/SDL_windowevents_c.h"

#include <stdarg.h>
#include <stdio.h>

/* The bridge API and its slot numbers live here. Included early because the
 * bridge code below uses them; the file's own later include of this header comes
 * after it. */
#include "SDL_openharmonyvideo.h"


/*
 * Exported for the launcher: lets it ask a given COPY of libSDL3.so what window
 * it is holding, which is how the copy that creates the window is identified.
 * Load-bearing for the window (see the copy-boundary note below), not a probe.
 */

/*
 * ---------------------------------------------------------------------------
 * PLATFORM WORKAROUND: the XComponent's window has to cross a copy boundary.
 *
 * Two independent mappings of libSDL3.so end up in this process. The one the
 * ArkTS XComponent loads receives the native window in its callbacks; the one the
 * game's LWJGL bindings load is the one the game asks for a window through. Each
 * mapping has its own copy of native_xcomponent/native_window, so the window
 * handed to the first is invisible to the second, and the game fails with
 * "Don't have Native XComponent or Native Window" even though the surface was
 * created and -- measured -- never destroyed.
 *
 * These are ordinary process-local addresses, just as valid in one mapping as in
 * the other, so the value is passed between them through a small file: whichever
 * mapping receives the window records it, and whichever mapping is asked for a
 * window it does not have reads it back.
 *
 * Remove this if the two loads are ever made to resolve to one mapping.
 * ---------------------------------------------------------------------------
 */
#include <stdlib.h>

#define OHOS_BRIDGE_DEFAULT "/data/storage/el2/base/files/sdl_surface_bridge"

/*
 * Two values have to cross the copy boundary: the XComponent and its native
 * window. The callbacks that receive them run in the mapping of this library that
 * ArkTS loaded, while the window is created in the other one, so neither mapping
 * has both halves.
 *
 * The SDL_Window is deliberately NOT among them. It was tried, and it is wrong:
 * a window belongs to the mapping that created it, along with the event queue
 * that SDL_SendEvent pushes into, so using it from the other mapping corrupts
 * memory. The window slot below is left unused for that reason. The mapping that
 * creates the window takes the input callbacks over instead -- see
 * SDL_OpenHarmonyAdoptXComponent.
 *
 * Each side writes only the slot it knows about and reads the rest, so the writes
 * merge rather than clobber.
 */
/* the slot numbers and the API are in SDL_openharmonyvideo.h */

static const char *ohos_bridge_path(void)
{
    const char *p = getenv("SDL_OHOS_SURFACE_BRIDGE");
    return (p && *p) ? p : OHOS_BRIDGE_DEFAULT;
}

static void ohos_bridge_load_all(void **v)
{
    int i;
    for (i = 0; i < SDL_OPENHARMONY_BRIDGE_SLOTS; i++) {
        v[i] = NULL;
    }
    FILE *f = fopen(ohos_bridge_path(), "r");
    if (!f) {
        return;
    }
    unsigned long long a = 0, b = 0, c = 0;
    const int n = fscanf(f, "%llx %llx %llx", &a, &b, &c);
    fclose(f);
    if (n > 0) v[0] = (void *) (uintptr_t) a;
    if (n > 1) v[1] = (void *) (uintptr_t) b;
    if (n > 2) v[2] = (void *) (uintptr_t) c;
}

static void ohos_bridge_store_all(void *const *v)
{
    FILE *f = fopen(ohos_bridge_path(), "w");
    if (!f) {
        return;
    }
    /* %llx rather than %p: the reader parses hex, and %p is not required to
     * print a bare 0x-prefixed value for NULL. */
    fprintf(f, "%llx %llx %llx\n",
            (unsigned long long) (uintptr_t) v[0],
            (unsigned long long) (uintptr_t) v[1],
            (unsigned long long) (uintptr_t) v[2]);
    fclose(f);
}

/* Publish one slot, keeping whatever the other copy has already stored.
 * Not static: the window and event code in this same library use it too. */
void SDL_OpenHarmonyBridgeSet(int slot, void *value)
{
    if (slot < 0 || slot >= SDL_OPENHARMONY_BRIDGE_SLOTS) {
        return;
    }
    void *v[SDL_OPENHARMONY_BRIDGE_SLOTS];
    ohos_bridge_load_all(v);
    v[slot] = value;
    ohos_bridge_store_all(v);
}

void *SDL_OpenHarmonyBridgeGet(int slot)
{
    if (slot < 0 || slot >= SDL_OPENHARMONY_BRIDGE_SLOTS) {
        return NULL;
    }
    void *v[SDL_OPENHARMONY_BRIDGE_SLOTS];
    ohos_bridge_load_all(v);
    return v[slot];
}

#include "SDL_openharmonyvideo.h"
#include "SDL_openharmonyopengl.h"
#include "SDL_openharmonyclipboard.h"
#include "SDL_openharmonyevents.h"
#include "SDL_openharmonykeyboard.h"
#include "SDL_openharmonymouse.h"
//#include "SDL_openharmonytouch.h"
#include "SDL_openharmonywindow.h"
#include "SDL_openharmonyvulkan.h"
//#include "SDL_openharmonymessagebox.h"

#define OPENHARMONY_VID_DRIVER_NAME "openharmony"

#include "../SDL_egl_c.h"
#define OPENHARMONY_GLES_GetProcAddress  SDL_EGL_GetProcAddressInternal
#define OPENHARMONY_GLES_UnloadLibrary   SDL_EGL_UnloadLibrary
#define OPENHARMONY_GLES_SetSwapInterval SDL_EGL_SetSwapInterval
#define OPENHARMONY_GLES_GetSwapInterval SDL_EGL_GetSwapInterval
#define OPENHARMONY_GLES_DestroyContext   SDL_EGL_DestroyContext


static OH_NativeXComponent *native_xcomponent = NULL;
static void *native_window = NULL;

/*
 * Exported for the launcher -- see the note above the declaration: this is the
 * bridge's read side and the window depends on it, so it is not a probe.
 *
 * The surface log shows the library's constructor running twice, which means two
 * independent mappings of the same path exist, each with its own copy of the two
 * statics above -- and the XComponent fills in one while the game reads the
 * other. What that leaves open is which copy the launcher itself has: the same
 * one as the game, or the XComponent's, which already has the values.
 *
 * Exported with default visibility because the build hides everything else.
 */
__attribute__((visibility("default")))
void haohandc_probe_surface_copy(const char *tag)
{
}

void SDL_OpenHarmonyGetNativeWindowPointers(void **xcomponent, void **window)
{

    /*
     * This mapping was not the one the XComponent's callbacks landed in, so the
     * window it was given is recorded in the bridge file -- see the note above.
     * Adopting it here (rather than at load time) keeps it to the moment it is
     * actually needed and means a stale file cannot affect anything until
     * something asks for a window.
     */
    if (!native_xcomponent || !native_window) {
        void *c = SDL_OpenHarmonyBridgeGet(SDL_OPENHARMONY_BRIDGE_COMPONENT);
        void *w = SDL_OpenHarmonyBridgeGet(SDL_OPENHARMONY_BRIDGE_SURFACE);
        if (c && w) {
            native_xcomponent = (OH_NativeXComponent *) c;
            native_window = w;
        }
    }

    *xcomponent = (void *) native_xcomponent;
    *window = (void *) native_window;
}

void SDL_OpenHarmonyVideoSurfaceDestroyed(void *component, void *window)
{
    SDL_assert(native_xcomponent == ((OH_NativeXComponent *) component));  // right now we assume one surface, one window.
    native_xcomponent = NULL;
    native_window = NULL;
}

void SDL_OpenHarmonyVideoSurfaceChanged(void *component, void *window)
{
    SDL_assert(native_xcomponent == ((OH_NativeXComponent *) component));  // right now we assume one surface, one window.
    uint64_t w, h;
    OH_NativeXComponent_GetXComponentSize(native_xcomponent, native_window, &w, &h);
    /*
     * Only the mapping that owns the window may send it an event; in the other
     * one there is no event queue to send through. Borrowing the window across
     * the boundary for this was tried and aborts -- see openharmony_window() in
     * SDL_openharmonyevents.c. A resize observed before the callbacks have been
     * taken over is simply dropped, and the size the window was created with is
     * the one the XComponent already had.
     */
    if (!OPENHARMONY_Window) {
        return;
    }
    SDL_SendWindowEvent(OPENHARMONY_Window, SDL_EVENT_WINDOW_RESIZED, (int) w, (int) h);
}

void SDL_OpenHarmonyVideoSurfaceCreated(void *component, void *window)
{
    SDL_assert(native_xcomponent == NULL);  // right now we assume one surface, one window.
    native_xcomponent = (OH_NativeXComponent *) component;
    native_window = window;
    /* record them for the other mapping of this library, if there is one */
    SDL_OpenHarmonyBridgeSet(SDL_OPENHARMONY_BRIDGE_COMPONENT, component);
    SDL_OpenHarmonyBridgeSet(SDL_OPENHARMONY_BRIDGE_SURFACE, window);
}

static bool OPENHARMONY_SuspendScreenSaver(SDL_VideoDevice *_this)
{
    return SDL_OpenHarmonyChangeScreenSaver(!_this->suspend_screensaver);
}

static bool OPENHARMONY_VideoInit(SDL_VideoDevice *_this)
{
    SDL_VideoData *videodata = _this->internal;

    videodata->isPaused = false;
    videodata->isPausing = false;

    // !!! FIXME: eventually we'll want to enumerate displays, since you can probably plug in something
    // !!! FIXME:  through a USB-C to HDMI adapter, or maybe there will be separate "outer" screens vs
    // !!! FIXME:  an internal foldable one, but for now let's just get _something_ on _any_ display.
    uint64_t dispid64 = 0;
    if (OH_NativeDisplayManager_GetDefaultDisplayId(&dispid64) != DISPLAY_MANAGER_OK) {
        return SDL_SetError("Couldn't get default display id");
    }
    const uint32_t dispid = (uint32_t) dispid64;

    NativeDisplayManager_DisplayInfo *dispinfo = NULL;
    if (OH_NativeDisplayManager_CreateDisplayById(dispid, &dispinfo) != DISPLAY_MANAGER_OK) {  // (should really be called "CreateDisplayInfo", not "CreateDisplay")
        return SDL_SetError("Couldn't get default display info");
    }

    SDL_DisplayMode mode;
    SDL_zero(mode);
    mode.format = SDL_PIXELFORMAT_BGRA8888;  // !!! FIXME
    mode.w = (int) dispinfo->physicalWidth;
    mode.h = (int) dispinfo->physicalHeight;
    mode.refresh_rate = (float) dispinfo->refreshRate;
    mode.pixel_density = 1.0f;

    const NativeDisplayManager_Rotation rotation = dispinfo->rotation;
    const NativeDisplayManager_Orientation orientation = dispinfo->orientation;

    OH_NativeDisplayManager_DestroyDisplay(dispinfo);

    const SDL_DisplayID displayID = SDL_AddBasicVideoDisplay(&mode);
    if (displayID == 0) {
        return false;
    }

    SDL_VideoDisplay *display = SDL_GetVideoDisplay(displayID);

    switch (orientation) {
        case DISPLAY_MANAGER_PORTRAIT: display->natural_orientation = SDL_ORIENTATION_PORTRAIT; break;
        case DISPLAY_MANAGER_LANDSCAPE: display->natural_orientation = SDL_ORIENTATION_LANDSCAPE; break;
        case DISPLAY_MANAGER_PORTRAIT_INVERTED: display->natural_orientation = SDL_ORIENTATION_PORTRAIT_FLIPPED; break;
        case DISPLAY_MANAGER_LANDSCAPE_INVERTED: display->natural_orientation = SDL_ORIENTATION_LANDSCAPE_FLIPPED; break;
        default: display->natural_orientation = SDL_ORIENTATION_UNKNOWN; break;
    }

    // !!! FIXME: this is probably wrong, I think on OpenHarmony phones/tablets, these are setting both orientation and rotation, and this works out because most people are launching apps while holding the phone in portrait mode (0 rotation).
    // !!! FIXME: if I'm right, we should decide if this is a phone/tablet screen and just set the natural orientation to portrait and then use this code to calculate current orientation.
    if (rotation == DISPLAY_MANAGER_ROTATION_90) {  // rotations are clockwise on OpenHarmony.
        static const SDL_DisplayOrientation rotated[5] = { SDL_ORIENTATION_UNKNOWN, SDL_ORIENTATION_PORTRAIT, SDL_ORIENTATION_PORTRAIT_FLIPPED, SDL_ORIENTATION_LANDSCAPE_FLIPPED, SDL_ORIENTATION_LANDSCAPE };
        SDL_assert(((int) display->natural_orientation) < SDL_arraysize(rotated));
        display->current_orientation = rotated[(int) display->natural_orientation];
    } else if (rotation == DISPLAY_MANAGER_ROTATION_180) {  // rotations are clockwise on OpenHarmony.
        static const SDL_DisplayOrientation rotated[5] = { SDL_ORIENTATION_UNKNOWN, SDL_ORIENTATION_LANDSCAPE_FLIPPED, SDL_ORIENTATION_LANDSCAPE, SDL_ORIENTATION_PORTRAIT_FLIPPED, SDL_ORIENTATION_PORTRAIT };
        SDL_assert(((int) display->natural_orientation) < SDL_arraysize(rotated));
        display->current_orientation = rotated[(int) display->natural_orientation];
    } else if (rotation == DISPLAY_MANAGER_ROTATION_270) {  // rotations are clockwise on OpenHarmony.
        static const SDL_DisplayOrientation rotated[5] = { SDL_ORIENTATION_UNKNOWN, SDL_ORIENTATION_PORTRAIT_FLIPPED, SDL_ORIENTATION_PORTRAIT, SDL_ORIENTATION_LANDSCAPE, SDL_ORIENTATION_LANDSCAPE_FLIPPED };
        SDL_assert(((int) display->natural_orientation) < SDL_arraysize(rotated));
        display->current_orientation = rotated[(int) display->natural_orientation];
    } else {
        display->current_orientation = display->natural_orientation;
    }

    display->content_scale = mode.pixel_density;

    // !!! FIXME: look at SDL_OnApplicationDidChangeStatusBarOrientation() and do something similar.


// !!! FIXME
#if 0
    OPENHARMONY_InitTouch();
    OPENHARMONY_InitMouse();
#endif
    OPENHARMONY_InitClipboard(_this);

    // We're done!
    return true;
}

void OPENHARMONY_VideoQuit(SDL_VideoDevice *_this)
{
    OPENHARMONY_QuitClipboard(_this);

// !!! FIXME
#if 0
    OPENHARMONY_QuitMouse();
    OPENHARMONY_QuitTouch();
#endif
}

static void OPENHARMONY_DeleteDevice(SDL_VideoDevice *device)
{
    SDL_free(device->internal);
    SDL_free(device);
}

static SDL_VideoDevice *OPENHARMONY_CreateDevice(void)
{
    SDL_VideoDevice *device;
    SDL_VideoData *data;

    // Initialize all variables that we clean on shutdown
    device = (SDL_VideoDevice *)SDL_calloc(1, sizeof(SDL_VideoDevice));
    if (!device) {
        return NULL;
    }

    data = (SDL_VideoData *)SDL_calloc(1, sizeof(SDL_VideoData));
    if (!data) {
        SDL_free(device);
        return NULL;
    }

    device->internal = data;
    device->system_theme = SDL_GetOpenHarmonySystemTheme();

    // Set the function pointers
    device->VideoInit = OPENHARMONY_VideoInit;
    device->VideoQuit = OPENHARMONY_VideoQuit;

    device->CreateSDLWindow = OPENHARMONY_CreateWindow;
    device->SetWindowTitle = OPENHARMONY_SetWindowTitle;
    device->SetWindowFullscreen = OPENHARMONY_SetWindowFullscreen;
    device->MinimizeWindow = OPENHARMONY_MinimizeWindow;
    device->SetWindowResizable = OPENHARMONY_SetWindowResizable;
    device->DestroyWindow = OPENHARMONY_DestroyWindow;

    device->free = OPENHARMONY_DeleteDevice;

    // GL pointers
#ifdef SDL_VIDEO_OPENGL_EGL
    device->GL_LoadLibrary = OPENHARMONY_GLES_LoadLibrary;
    device->GL_GetProcAddress = OPENHARMONY_GLES_GetProcAddress;
    device->GL_UnloadLibrary = OPENHARMONY_GLES_UnloadLibrary;
    device->GL_CreateContext = OPENHARMONY_GLES_CreateContext;
    device->GL_MakeCurrent = OPENHARMONY_GLES_MakeCurrent;
    device->GL_SetSwapInterval = OPENHARMONY_GLES_SetSwapInterval;
    device->GL_GetSwapInterval = OPENHARMONY_GLES_GetSwapInterval;
    device->GL_SwapWindow = OPENHARMONY_GLES_SwapWindow;
    device->GL_DestroyContext = OPENHARMONY_GLES_DestroyContext;
#endif

#ifdef SDL_VIDEO_VULKAN
    device->Vulkan_LoadLibrary = OPENHARMONY_Vulkan_LoadLibrary;
    device->Vulkan_UnloadLibrary = OPENHARMONY_Vulkan_UnloadLibrary;
    device->Vulkan_GetInstanceExtensions = OPENHARMONY_Vulkan_GetInstanceExtensions;
    device->Vulkan_CreateSurface = OPENHARMONY_Vulkan_CreateSurface;
    device->Vulkan_DestroySurface = OPENHARMONY_Vulkan_DestroySurface;
#endif

    // Screensaver
    device->SuspendScreenSaver = OPENHARMONY_SuspendScreenSaver;

    device->PumpEvents = OPENHARMONY_PumpEvents;

    // Screen keyboard
    device->HasScreenKeyboardSupport = OPENHARMONY_HasScreenKeyboardSupport;
    device->ShowScreenKeyboard = OPENHARMONY_ShowScreenKeyboard;
    device->HideScreenKeyboard = OPENHARMONY_HideScreenKeyboard;

    // Clipboard
    device->GetTextMimeTypes = OPENHARMONY_GetTextMimeTypes;
    device->SetClipboardText = OPENHARMONY_SetClipboardText;
    device->GetClipboardText = OPENHARMONY_GetClipboardText;
    device->HasClipboardText = OPENHARMONY_HasClipboardText;

    device->device_caps = VIDEO_DEVICE_CAPS_SENDS_FULLSCREEN_DIMENSIONS;

    return device;
}

VideoBootStrap OPENHARMONY_bootstrap = {
    OPENHARMONY_VID_DRIVER_NAME, "SDL OpenHarmony/HarmonyOS video driver",
    OPENHARMONY_CreateDevice,
    /*!!! FIXME OPENHARMONY_ShowMessageBox*/ NULL,
    false
};

#endif // SDL_VIDEO_DRIVER_OPENHARMONY
