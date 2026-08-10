#pragma once
#include "AudioFormat.h"
#include <soxr.h>

// 采样率转换器，使用 SoX Resampler 将音频源转换为目标采样率。
class Resampler {
public:
    Resampler();
    ~Resampler();

    // 初始化重采样器，从源采样率转换到目标采样率。
    bool setup(int srcRate, int dstRate, int channels);
    // 关闭并释放重采样器资源。
    void close();

    // 重采样输入样本，返回输出帧数。
    int process(const float* input, int inputFrames,
                float* output, int maxOutputFrames);

    bool isActive() const { return soxr_ != nullptr; }
    int outputRate() const { return dstRate_; }

private:
    soxr_t soxr_ = nullptr;
    int srcRate_ = 0;
    int dstRate_ = 0;
    int channels_ = 2;
};
