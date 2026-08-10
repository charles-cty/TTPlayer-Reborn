#pragma once
#include "AudioFormat.h"
#include <cmath>
#include <array>
#include <vector>

// 单声道 IIR Biquad 滤波器
struct BiquadFilter {
    double b0 = 1.0, b1 = 0, b2 = 0;
    double a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;

    void reset() { z1 = z2 = 0; }

    double process(double x) {
        double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }

    // 峰值均衡器系数计算
    void setPeakingEQ(double sampleRate, double freq, double gainDb, double Q) {
        double A = std::pow(10.0, gainDb / 40.0);
        double w0 = 2.0 * M_PI * freq / sampleRate;
        double sinw0 = std::sin(w0);
        double cosw0 = std::cos(w0);
        double alpha = sinw0 / (2.0 * Q);

        double a0 = 1.0 + alpha / A;
        b0 = (1.0 + alpha * A) / a0;
        b1 = (-2.0 * cosw0) / a0;
        b2 = (1.0 - alpha * A) / a0;
        a1 = (-2.0 * cosw0) / a0;
        a2 = (1.0 - alpha / A) / a0;
    }
};

// 10 波段参数均衡器，模拟原版 TTPlayer 的频段设置。
class Equalizer {
public:
    // 标准 10 波段中心频率
    static constexpr std::array<double, 10> FREQUENCIES = {
        31.0, 62.0, 125.0, 250.0, 500.0,
        1000.0, 2000.0, 4000.0, 8000.0, 16000.0
    };

    // 设置采样率并更新滤波器系数。
    void setSampleRate(int sampleRate) {
        sampleRate_ = sampleRate;
        updateCoefficients();
    }

    void setEnabled(bool enabled) { enabled_ = enabled; }
    bool isEnabled() const { return enabled_; }

    // 设置波段增益，单位 dB，范围 [-12, +12]
    void setBandGain(int band, double gainDb) {
        if (band < 0 || band >= 10) return;
        bandGains_[band] = gainDb;
        updateCoefficients();
    }

    double bandGain(int band) const {
        if (band < 0 || band >= 10) return 0;
        return bandGains_[band];
    }

    void setPreamp(double gainDb) {
        preamp_ = gainDb;
    }

    double preamp() const { return preamp_; }

    // 重置所有滤波器状态，清除历史采样。
    void reset() {
        for (auto& bandFilters : filters_) {
            for (auto& f : bandFilters) f.reset();
        }
    }

    // 原地处理交错浮点样本
    void process(float* data, int frames, int channels) {
        if (!enabled_) return;

        double preampLinear = std::pow(10.0, preamp_ / 20.0);

        for (int i = 0; i < frames; ++i) {
            for (int ch = 0; ch < channels && ch < 2; ++ch) {
                double sample = data[i * channels + ch] * preampLinear;
                for (int band = 0; band < 10; ++band) {
                    sample = filters_[band][ch].process(sample);
                }
                data[i * channels + ch] = static_cast<float>(sample);
            }
        }
    }

private:
    // 更新所有频段滤波器系数，基于当前采样率和增益值。
    void updateCoefficients() {
        for (int band = 0; band < 10; ++band) {
            for (int ch = 0; ch < 2; ++ch) {
                filters_[band][ch].setPeakingEQ(
                    sampleRate_, FREQUENCIES[band], bandGains_[band], 1.4);
            }
        }
    }

    bool enabled_ = false;
    int sampleRate_ = 44100;
    double preamp_ = 0.0;
    std::array<double, 10> bandGains_ = {};
    std::array<std::array<BiquadFilter, 2>, 10> filters_; // [band][channel]
};
