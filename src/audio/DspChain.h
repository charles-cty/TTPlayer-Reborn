#pragma once
#include "AudioFormat.h"
#include "Equalizer.h"
#include <cmath>
#include <algorithm>

// 数字信号处理链，串联均衡、平衡、音量和淡入淡出效果。
class DspChain {
public:
    void setSampleRate(int rate) {
        equalizer.setSampleRate(rate);
    }

    // 原地处理音频缓冲区
    void process(float* data, int frames, int channels) {
        // 1. 应用均衡器处理
        equalizer.process(data, frames, channels);

        // 2. 处理声道平衡
        if (std::abs(balance_) > 0.01f && channels >= 2) {
            applyBalance(data, frames, channels);
        }

        // 3. 应用音量和静音
        float vol = muted_ ? 0.0f : volume_;
        if (std::abs(vol - 1.0f) > 0.001f) {
            int total = frames * channels;
            for (int i = 0; i < total; ++i) {
                data[i] *= vol;
            }
        }

        // 4. 淡入淡出处理（如果处于活动状态）
        if (fadeRemaining_ > 0) {
            applyFade(data, frames, channels);
        }
    }

    // 音量范围 [0.0, 1.0]
    void setVolume(float v) { volume_ = std::clamp(v, 0.0f, 1.0f); }
    float volume() const { return volume_; }

    void setMuted(bool m) { muted_ = m; }
    bool isMuted() const { return muted_; }

    // 声道平衡范围 [-1.0（左）到 +1.0（右）]
    void setBalance(float b) { balance_ = std::clamp(b, -1.0f, 1.0f); }
    float balance() const { return balance_; }

    // 开始一个指定帧数的淡出效果
    // 开始淡出效果，在指定帧数内音量逐渐减小到 0。
    void startFadeOut(int frames) {
        fadeRemaining_ = frames;
        fadeTotal_ = frames;
        fadingOut_ = true;
    }

    // 开始淡入效果，在指定帧数内音量从 0 增加到当前值。
    void startFadeIn(int frames) {
        fadeRemaining_ = frames;
        fadeTotal_ = frames;
        fadingOut_ = false;
    }

    // 判断是否正在执行淡入/淡出处理。
    bool isFading() const { return fadeRemaining_ > 0; }

    Equalizer equalizer;

private:
    void applyBalance(float* data, int frames, int channels) {
        for (int i = 0; i < frames; ++i) {
            if (balance_ < 0) {
                // 减弱右声道
                data[i * channels + 1] *= (1.0f + balance_);
            } else {
                // 减弱左声道
                data[i * channels + 0] *= (1.0f - balance_);
            }
        }
    }

    void applyFade(float* data, int frames, int channels) {
        for (int i = 0; i < frames && fadeRemaining_ > 0; ++i) {
            float ratio = static_cast<float>(fadeRemaining_) / fadeTotal_;
            float gain = fadingOut_ ? ratio : (1.0f - ratio);
            for (int ch = 0; ch < channels; ++ch) {
                data[i * channels + ch] *= gain;
            }
            --fadeRemaining_;
        }
    }

    float volume_ = 1.0f;
    bool muted_ = false;
    float balance_ = 0.0f;
    int fadeRemaining_ = 0;
    int fadeTotal_ = 0;
    bool fadingOut_ = false;
};
