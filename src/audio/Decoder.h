#pragma once
#include <string>
#include <memory>
#include <functional>
#include "AudioFormat.h"
#include "Utf8Avio.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

// 音频解码器，基于 FFmpeg 解码音频文件并输出 float 格式音频样本。
class Decoder {
public:
    Decoder();
    ~Decoder();

    // 打开音频文件并准备解码。
    bool open(const std::string& filePath);
    // 关闭解码器并释放资源。
    void close();
    // 判断解码器是否已成功打开。
    bool isOpen() const;

    // 读取解码后的浮点交错音频数据
    // 返回读取的帧数，EOF 返回 0，出错返回 -1
    int read(AudioBuffer& buffer, int maxFrames);

    // 跳转到指定毫秒位置，准备从该位置继续读取。
    bool seek(int64_t positionMs);

    const AudioFormat& format() const { return format_; }
    int64_t durationMs() const;
    int64_t positionMs() const;
    const std::string& lastError() const { return lastError_; }

    // 元数据
    // 获取音频文件标题。
    std::string title() const;
    // 获取音频文件艺术家。
    std::string artist() const;
    // 获取音频文件专辑。
    std::string album() const;
    // 获取音频文件封面图二进制数据。
    const std::vector<unsigned char>& coverArtData() const { return coverArtData_; }

private:
    bool decodeNextFrame();
    bool receiveDecodedFrame();
    bool convertCurrentFrame();

    AVFormatContext* fmtCtx_ = nullptr;
    AVCodecContext* codecCtx_ = nullptr;
    SwrContext* swrCtx_ = nullptr;
    AVFrame* frame_ = nullptr;
    AVPacket* packet_ = nullptr;
    int audioStreamIndex_ = -1;
    AudioFormat format_;
    bool isOpen_ = false;
    int64_t currentPts_ = 0;

    // 解码后的样本缓冲区（浮点、交错格式）
    std::vector<float> decodedBuf_;
    int decodedBufPos_ = 0;
    int decodedBufFrames_ = 0;
    std::vector<unsigned char> coverArtData_;
    std::string lastError_;
    bool draining_ = false;
    Utf8Avio utf8Avio_;
};
