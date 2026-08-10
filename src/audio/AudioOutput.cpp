#include "AudioOutput.h"
#include <cstring>

// 构造函数：初始化 SDL 音频子系统。
AudioOutput::AudioOutput() {
    SDL_Init(SDL_INIT_AUDIO);
}

// 析构函数：关闭音频设备并释放资源。
AudioOutput::~AudioOutput() {
    close();
}

// 打开音频设备并准备回调填充输出数据。
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

    SDL_AudioSpec desired{}, obtained{};
    desired.freq = sampleRate;
    desired.format = AUDIO_F32SYS;
    desired.channels = static_cast<uint8_t>(channels);
    desired.samples = 2048;
    desired.callback = sdlCallback;
    desired.userdata = this;

    device_ = SDL_OpenAudioDevice(nullptr, 0, &desired, &obtained, 0);
    if (device_ == 0) return false;

    sampleRate_ = obtained.freq;
    channels_ = obtained.channels;
    return true;
}

bool AudioOutput::isCompatible(int sampleRate, int channels) const {
    return device_ != 0 && sampleRate_ == sampleRate && channels_ == channels;
}

// 关闭当前音频设备。
void AudioOutput::close() {
    if (device_) {
        SDL_CloseAudioDevice(device_);
        device_ = 0;
    }
    playing_ = false;
}

// 启动音频播放。
void AudioOutput::start() {
    if (device_) {
        SDL_PauseAudioDevice(device_, 0);
        playing_ = true;
    }
}

// 暂停音频播放。
void AudioOutput::pause() {
    if (device_) {
        SDL_PauseAudioDevice(device_, 1);
        playing_ = false;
    }
}

// SDL 回调函数，将设备请求的数据传给外部回调。
void AudioOutput::sdlCallback(void* userdata, uint8_t* stream, int len) {
    auto* self = static_cast<AudioOutput*>(userdata);
    int frames = len / (sizeof(float) * self->channels_);
    auto* buf = reinterpret_cast<float*>(stream);

    if (self->callback_) {
        self->callback_(buf, frames);
    } else {
        std::memset(stream, 0, len);
    }
}
