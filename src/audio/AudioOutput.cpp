#include "AudioOutput.h"
#include <cstring>
#include <string>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace {

std::string gUserAudioDriver;
bool gUserAudioDriverCaptured = false;

void captureUserAudioDriver() {
    if (gUserAudioDriverCaptured) {
        return;
    }
    gUserAudioDriverCaptured = true;
    const char* e = SDL_getenv("SDL_AUDIODRIVER");
    if (e && e[0]) {
        gUserAudioDriver = e;
    }
#ifdef _WIN32
    if (gUserAudioDriver.empty()) {
        char buf[64]{};
        const DWORD n = GetEnvironmentVariableA("SDL_AUDIODRIVER", buf, sizeof(buf));
        if (n > 0 && n < sizeof(buf)) {
            gUserAudioDriver = buf;
        }
    }
#endif
}

bool userLockedAudioDriver() {
    captureUserAudioDriver();
    return !gUserAudioDriver.empty();
}

#ifdef _WIN32
const char* kFallbackDrivers[] = {"wasapi", "directsound", "winmm", nullptr};
#else
const char* kFallbackDrivers[] = {"pulse", "pipewire", "alsa", nullptr};
#endif

bool initWithDriver(const char* driver) {
    const char* current = SDL_GetCurrentAudioDriver();
    if (SDL_WasInit(SDL_INIT_AUDIO)) {
        if (!driver || (current && std::strcmp(current, driver) == 0)) {
            return true;
        }
        SDL_QuitSubSystem(SDL_INIT_AUDIO);
        if (SDL_WasInit(0) == 0) {
            SDL_Quit();
        }
    }
    if (driver && driver[0]) {
        SDL_setenv("SDL_AUDIODRIVER", driver, 1);
#ifdef _WIN32
        SetEnvironmentVariableA("SDL_AUDIODRIVER", driver);
#endif
    }
    return SDL_InitSubSystem(SDL_INIT_AUDIO) == 0;
}

std::string sdlErrorOr(const char* fallback) {
    const char* e = SDL_GetError();
    if (e && e[0]) {
        return e;
    }
    return fallback;
}

} // namespace

AudioOutput::AudioOutput() {
    captureUserAudioDriver();
}

AudioOutput::~AudioOutput() {
    close();
}

bool AudioOutput::openDevice(const char* deviceName, int sampleRate, int channels) {
    SDL_AudioSpec desired{};
    SDL_AudioSpec obtained{};
    desired.freq = sampleRate;
    desired.format = AUDIO_F32SYS;
    desired.channels = static_cast<uint8_t>(channels);
    desired.samples = 2048;
    desired.callback = sdlCallback;
    desired.userdata = this;

    // Keep rate/channels/format so the fill callback still sees float PCM at
    // the decoder rate. SDL converts internally when allowed_changes is 0.
    device_ = SDL_OpenAudioDevice(deviceName, 0, &desired, &obtained, 0);
    if (device_ == 0) {
        lastError_ = sdlErrorOr("SDL_OpenAudioDevice failed");
        return false;
    }
    if (obtained.format != AUDIO_F32SYS || obtained.channels != channels ||
        obtained.freq != sampleRate) {
        SDL_CloseAudioDevice(device_);
        device_ = 0;
        lastError_ = "audio device opened with incompatible spec";
        return false;
    }
    sampleRate_ = obtained.freq;
    channels_ = obtained.channels;
    return true;
}

bool AudioOutput::openOnCurrentDriver(int sampleRate, int channels) {
    if (openDevice(nullptr, sampleRate, channels)) {
        lastError_.clear();
        return true;
    }
    const int n = SDL_GetNumAudioDevices(0);
    for (int i = 0; i < n; ++i) {
        const char* name = SDL_GetAudioDeviceName(i, 0);
        if (openDevice(name, sampleRate, channels)) {
            lastError_.clear();
            return true;
        }
    }
    return false;
}

bool AudioOutput::open(int sampleRate, int channels, FillCallback callback) {
    if (device_ && isCompatible(sampleRate, channels)) {
        SDL_LockAudioDevice(device_);
        callback_ = std::move(callback);
        SDL_UnlockAudioDevice(device_);
        return true;
    }

    close();

    callback_ = std::move(callback);
    sampleRate_ = sampleRate;
    channels_ = channels;
    lastError_.clear();

    auto fail = [this]() {
        callback_ = nullptr;
        return false;
    };

    if (userLockedAudioDriver()) {
        if (!initWithDriver(gUserAudioDriver.c_str())) {
            lastError_ = sdlErrorOr("SDL_Init audio failed");
            return fail();
        }
        if (openOnCurrentDriver(sampleRate, channels)) {
            return true;
        }
        return fail();
    }

    std::string err;
    for (int i = 0; kFallbackDrivers[i]; ++i) {
        if (!initWithDriver(kFallbackDrivers[i])) {
            err = sdlErrorOr("SDL_Init audio failed");
            continue;
        }
        if (openOnCurrentDriver(sampleRate, channels)) {
            return true;
        }
        err = lastError_;
        close();
        if (SDL_WasInit(SDL_INIT_AUDIO)) {
            SDL_QuitSubSystem(SDL_INIT_AUDIO);
        }
        if (SDL_WasInit(0) == 0) {
            SDL_Quit();
        }
    }

    lastError_ = err.empty() ? "Failed to open audio output" : err;
    const char* drv = SDL_GetCurrentAudioDriver();
    if (drv && drv[0]) {
        lastError_ += std::string(" (driver=") + drv + ")";
    }
    return fail();
}

bool AudioOutput::isCompatible(int sampleRate, int channels) const {
    return device_ != 0 && sampleRate_ == sampleRate && channels_ == channels;
}

void AudioOutput::close() {
    if (device_) {
        SDL_CloseAudioDevice(device_);
        device_ = 0;
    }
    playing_ = false;
}

void AudioOutput::start() {
    if (device_) {
        SDL_PauseAudioDevice(device_, 0);
        playing_ = true;
    }
}

void AudioOutput::pause() {
    if (device_) {
        SDL_PauseAudioDevice(device_, 1);
        playing_ = false;
    }
}

void AudioOutput::sdlCallback(void* userdata, uint8_t* stream, int len) {
    auto* self = static_cast<AudioOutput*>(userdata);
    if (self->channels_ <= 0) {
        std::memset(stream, 0, static_cast<size_t>(len));
        return;
    }
    int frames = len / (static_cast<int>(sizeof(float)) * self->channels_);
    auto* buf = reinterpret_cast<float*>(stream);

    if (self->callback_ && frames > 0) {
        self->callback_(buf, frames);
    } else {
        std::memset(stream, 0, static_cast<size_t>(len));
    }
}
