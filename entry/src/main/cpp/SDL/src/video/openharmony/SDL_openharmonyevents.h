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

#include "../SDL_sysvideo.h"

// src/core/openharmony/SDL_openharmony.c calls these when it gets events from the system.
extern void SDL_OpenHarmonyDispatchTouchEvent(void *component, void *window);
extern void SDL_OpenHarmonyDispatchMouseEvent(void *component, void *window);
extern void SDL_OpenHarmonyDispatchKeyEvent(void *component, void *window);
extern void SDL_OpenHarmonyDispatchUIInputEvent(void *component, void *event, int32_t type);

extern void OPENHARMONY_InitEvents(void);
extern void OPENHARMONY_PumpEvents(SDL_VideoDevice *_this);
extern void OPENHARMONY_QuitEvents(void);

/*
 * Text input is provided by the app's ArkUI layer rather than by SDL's own IME
 * path, which cannot work in this process (two mappings of libSDL3.so; ArkTS
 * gives the IME controller to the one that is not running the game). See the
 * long note in SDL_openharmony.c above SDL_OpenHarmonyShowScreenKeyboard.
 *
 * All three are written in the app's application-level files directory, which is
 * the one native code and ArkTS share. Note that ArkTS's own context.filesDir is
 * the HAP-level directory and is a DIFFERENT place -- using it here would
 * silently never be seen.
 *
 * RECT carries the game's text field as "x y w h", so the app can place its own
 * invisible text field exactly over it and let the framework's keyboard
 * avoidance move the page by the right amount. See IMEBridgePublishRect.
 */
#define SDL_OPENHARMONY_IME_WANT_FILE "/data/storage/el2/base/files/ime_want"
#define SDL_OPENHARMONY_IME_CMD_FILE  "/data/storage/el2/base/files/ime_cmd"
#define SDL_OPENHARMONY_IME_RECT_FILE "/data/storage/el2/base/files/ime_rect"
