/*
SoLoud audio engine
Copyright (c) 2013-2015 Jari Komppa

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
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

   3. This notice may not be removed or altered from any source
   distribution.
*/

// SDL3 audio backend.
//
// SDL3 replaced the callback-style SDL_OpenAudioDevice from SDL2 with a stream API:
// SDL_OpenAudioDeviceStream() hands back an SDL_AudioStream and invokes a callback
// whenever more data is wanted, and the callback pushes samples in with
// SDL_PutAudioStreamData(). The stream accepts SDL_AUDIO_F32 and converts to whatever
// the device actually wants, so there is no format negotiation to do here.
//
// This backend exists because the platforms that matter here only ship an SDL3 audio
// driver (OpenHarmony has OHAudio and no ALSA/PulseAudio), so SoLoud's ALSA/miniaudio
// backends cannot open a device at all.

#include <stdlib.h>

#include "soloud.h"

#if !defined(WITH_SDL3)

namespace SoLoud {
result sdl3_init(SoLoud::Soloud *aSoloud, unsigned int aFlags, unsigned int aSamplerate, unsigned int aBuffer, unsigned int aChannels){
    return NOT_IMPLEMENTED;
}
} // namespace SoLoud

#else

#include <math.h>
#include <vector>

#include <SDL3/SDL.h>

namespace SoLoud {
static SDL_AudioStream *gAudioStream = NULL;
static int gChannels = 2;

// held across callbacks so the mixer does not allocate on the audio thread after warm-up
static std::vector<float> gMixBuffer;

static void SDLCALL soloud_sdl3_audiomixer(void *userdata, SDL_AudioStream *stream, int additional_amount, int total_amount){
    if(additional_amount <= 0){
        return;
    }

    SoLoud::Soloud *soloud = (SoLoud::Soloud *)userdata;
    if(soloud == NULL || gChannels <= 0){
        return;
    }

    // additional_amount counts bytes of float samples, not frames
    int samples = additional_amount / (int)(sizeof(float) * (size_t)gChannels);
    if(samples <= 0){
        return;
    }

    // cap each pass; the request can be large and we would rather be called again
    const int maxSamples = 4096;
    while(samples > 0){
        int chunk = samples > maxSamples ? maxSamples : samples;
        gMixBuffer.resize((size_t)chunk * (size_t)gChannels);
        soloud->mix(gMixBuffer.data(), (unsigned int)chunk);

        if(!SDL_PutAudioStreamData(stream, gMixBuffer.data(), (int)(gMixBuffer.size() * sizeof(float)))){
            break;
        }
        samples -= chunk;
    }
}

static void soloud_sdl3_deinit(SoLoud::Soloud *aSoloud){
    if(gAudioStream != NULL){
        SDL_DestroyAudioStream(gAudioStream);
        gAudioStream = NULL;
    }
}

result sdl3_init(SoLoud::Soloud *aSoloud, unsigned int aFlags, unsigned int aSamplerate, unsigned int aBuffer, unsigned int aChannels){
    if(!SDL_WasInit(SDL_INIT_AUDIO)){
        if(!SDL_InitSubSystem(SDL_INIT_AUDIO)){
            return UNKNOWN_ERROR;
        }
    }

    SDL_AudioSpec spec;
    spec.format = SDL_AUDIO_F32;
    spec.channels = (int)aChannels;
    spec.freq = (int)aSamplerate;

    gChannels = (int)aChannels;

    gAudioStream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, soloud_sdl3_audiomixer, (void *)aSoloud);
    if(gAudioStream == NULL){
        return UNKNOWN_ERROR;
    }

    // the device may not accept what we asked for; report what it settled on
    SDL_AudioSpec src;
    SDL_AudioSpec dst;
    if(SDL_GetAudioStreamFormat(gAudioStream, &src, &dst)){
        if(src.channels > 0){
            gChannels = src.channels;
        }
        if(src.freq > 0){
            aSamplerate = (unsigned int)src.freq;
        }
    }

    aSoloud->postinit_internal(aSamplerate, aBuffer, aFlags, (unsigned int)gChannels);

    aSoloud->mBackendCleanupFunc = soloud_sdl3_deinit;

    SDL_ResumeAudioStreamDevice(gAudioStream);
    aSoloud->mBackendString = "SDL3";
    aSoloud->mBackendID = Soloud::SDL3;
    return 0;
}
} // namespace SoLoud
#endif
