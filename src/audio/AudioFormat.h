#pragma once
#include <cstdint>
#include <string>
#include <vector>

struct AudioFormat {
    int sampleRate = 44100;
    int channels = 2;
    int bitsPerSample = 16;
    int64_t totalSamples = 0;  // 0 表示未知
};

// 交错浮点样本，范围 [-1.0, 1.0]
struct AudioBuffer {
    std::vector<float> data;
    int channels = 2;
    int sampleRate = 44100;

    int frameCount() const {
        return channels > 0 ? static_cast<int>(data.size()) / channels : 0;
    }
};
