#pragma once
#include "AudioFormat.h"
#include <SDL2/SDL.h>
#include <functional>
#include <string>

// 音频输出包装器，封装 SDL 音频设备和回调机制。
class AudioOutput {
public:
    using FillCallback = std::function<void(float* buffer, int frames)>;

    AudioOutput();
    ~AudioOutput();

    bool open(int sampleRate, int channels, FillCallback callback);
    void close();
    void start();
    void pause();
    bool isPlaying() const { return playing_; }
    bool isCompatible(int sampleRate, int channels) const;
    const std::string& lastError() const { return lastError_; }

    int sampleRate() const { return sampleRate_; }
    int channels() const { return channels_; }

private:
    static void sdlCallback(void* userdata, uint8_t* stream, int len);
    bool openDevice(const char* deviceName, int sampleRate, int channels);
    bool openOnCurrentDriver(int sampleRate, int channels);

    SDL_AudioDeviceID device_ = 0;
    FillCallback callback_;
    int sampleRate_ = 44100;
    int channels_ = 2;
    bool playing_ = false;
    std::string lastError_;
};
