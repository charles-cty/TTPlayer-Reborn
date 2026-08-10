#pragma once
#include "AudioFormat.h"
#include <SDL2/SDL.h>
#include <functional>
#include <mutex>
#include <vector>

// 音频输出包装器，封装 SDL 音频设备和回调机制。
class AudioOutput {
public:
    using FillCallback = std::function<void(float* buffer, int frames)>;

    // 初始化 SDL 音频子系统。
    AudioOutput();
    ~AudioOutput();

    // 打开音频设备并注册回调以填充输出缓冲区。
    bool open(int sampleRate, int channels, FillCallback callback);
    // 关闭当前音频设备。
    void close();
    // 启动音频播放。
    void start();
    // 暂停音频播放。
    void pause();
    bool isPlaying() const { return playing_; }
    bool isCompatible(int sampleRate, int channels) const;

    int sampleRate() const { return sampleRate_; }
    int channels() const { return channels_; }

private:
    static void sdlCallback(void* userdata, uint8_t* stream, int len);

    SDL_AudioDeviceID device_ = 0;
    FillCallback callback_;
    int sampleRate_ = 44100;
    int channels_ = 2;
    bool playing_ = false;
};
