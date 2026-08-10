#include "Resampler.h"

// 构造函数：初始化重采样器对象。
Resampler::Resampler() = default;

// 析构函数：关闭重采样器并释放资源。
Resampler::~Resampler() {
    close();
}

// 配置并创建 SoX 重采样器对象。
bool Resampler::setup(int srcRate, int dstRate, int channels) {
    close();

    if (srcRate == dstRate) return true; // 不需要重采样

    srcRate_ = srcRate;
    dstRate_ = dstRate;
    channels_ = channels;

    soxr_error_t error;
    soxr_io_spec_t ioSpec = soxr_io_spec(SOXR_FLOAT32_I, SOXR_FLOAT32_I);
    soxr_quality_spec_t qSpec = soxr_quality_spec(SOXR_VHQ, 0); // 非常高质量

    soxr_ = soxr_create(srcRate, dstRate, channels, &error, &ioSpec, &qSpec, nullptr);
    return soxr_ != nullptr;
}

// 释放 SoX 重采样器资源。
void Resampler::close() {
    if (soxr_) {
        soxr_delete(soxr_);
        soxr_ = nullptr;
    }
}

// 对输入样本执行重采样，并返回输出帧数。
int Resampler::process(const float* input, int inputFrames,
                        float* output, int maxOutputFrames) {
    if (!soxr_) return 0;

    size_t idone, odone;
    soxr_error_t error = soxr_process(soxr_,
        input, inputFrames, &idone,
        output, maxOutputFrames, &odone);

    if (error) return -1;
    return static_cast<int>(odone);
}
