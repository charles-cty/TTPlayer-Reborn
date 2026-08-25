#include "Decoder.h"
#include <cstring>
#include <algorithm>

namespace {
std::string ffmpegErrorString(int errnum) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(errnum, buffer, sizeof(buffer));
    return buffer;
}
}

// 构造函数：分配 FFmpeg 帧和数据包对象。
Decoder::Decoder() {
    frame_ = av_frame_alloc();
    packet_ = av_packet_alloc();
}

// 析构函数：关闭解码器并释放 FFmpeg 资源。
Decoder::~Decoder() {
    close();
    av_frame_free(&frame_);
    av_packet_free(&packet_);
}

// 打开音频文件，查找音频流并初始化解码器与重采样器。
bool Decoder::open(const std::string& filePath) {
    close();
    lastError_.clear();

    int ret = avformat_open_input(&fmtCtx_, filePath.c_str(), nullptr, nullptr);
    if (ret < 0) {
        lastError_ = "Failed to open input: " + ffmpegErrorString(ret);
        return false;
    }

    ret = avformat_find_stream_info(fmtCtx_, nullptr);
    if (ret < 0) {
        lastError_ = "Failed to read stream info: " + ffmpegErrorString(ret);
        close();
        return false;
    }

    coverArtData_.clear();
    for (unsigned int i = 0; i < fmtCtx_->nb_streams; ++i) {
        auto* stream = fmtCtx_->streams[i];
        if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 &&
            stream->attached_pic.size > 0 && stream->attached_pic.data) {
            const auto* begin = stream->attached_pic.data;
            coverArtData_.assign(begin, begin + stream->attached_pic.size);
            break;
        }
    }

    // 查找最佳音频流
    audioStreamIndex_ = av_find_best_stream(fmtCtx_, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (audioStreamIndex_ < 0) {
        lastError_ = "No audio stream found";
        close();
        return false;
    }

    auto* stream = fmtCtx_->streams[audioStreamIndex_];
    auto* codecPar = stream->codecpar;

    // 查找解码器
    const AVCodec* codec = avcodec_find_decoder(codecPar->codec_id);
    if (!codec) {
        lastError_ = "No decoder available for codec id " + std::to_string(codecPar->codec_id);
        close();
        return false;
    }

    codecCtx_ = avcodec_alloc_context3(codec);
    if (!codecCtx_) {
        lastError_ = "Failed to allocate codec context";
        close();
        return false;
    }

    ret = avcodec_parameters_to_context(codecCtx_, codecPar);
    if (ret < 0) {
        lastError_ = "Failed to copy codec parameters: " + ffmpegErrorString(ret);
        close();
        return false;
    }
    codecCtx_->pkt_timebase = stream->time_base;

    ret = avcodec_open2(codecCtx_, codec, nullptr);
    if (ret < 0) {
        lastError_ = "Failed to open codec: " + ffmpegErrorString(ret);
        close();
        return false;
    }

    AVChannelLayout inLayout = codecCtx_->ch_layout;
    if (inLayout.nb_channels <= 0) {
        inLayout = codecPar->ch_layout;
    }
    if (inLayout.nb_channels <= 0) {
        lastError_ = "Audio stream has no valid channel layout";
        close();
        return false;
    }

    // 初始化重采样器，将任意格式转换为浮点交错格式。
    AVChannelLayout outLayout{};
    ret = av_channel_layout_copy(&outLayout, &inLayout);
    if (ret < 0) {
        av_channel_layout_default(&outLayout, inLayout.nb_channels);
    }

    ret = swr_alloc_set_opts2(&swrCtx_,
        &outLayout, AV_SAMPLE_FMT_FLT, codecCtx_->sample_rate,
        &inLayout, codecCtx_->sample_fmt, codecCtx_->sample_rate,
        0, nullptr);
    av_channel_layout_uninit(&outLayout);
    if (ret < 0) {
        lastError_ = "Failed to configure resampler: " + ffmpegErrorString(ret);
        close();
        return false;
    }

    ret = swr_init(swrCtx_);
    if (ret < 0) {
        lastError_ = "Failed to initialize resampler: " + ffmpegErrorString(ret);
        close();
        return false;
    }

    format_.sampleRate = codecCtx_->sample_rate;
    format_.channels = inLayout.nb_channels;
    format_.bitsPerSample = 32; // 浮点输出
    if (stream->duration > 0 && stream->duration != AV_NOPTS_VALUE) {
        format_.totalSamples = av_rescale_q(stream->duration, stream->time_base,
                                            AVRational{1, format_.sampleRate});
    } else if (fmtCtx_->duration > 0) {
        format_.totalSamples = av_rescale(fmtCtx_->duration, format_.sampleRate, AV_TIME_BASE);
    }

    isOpen_ = true;
    currentPts_ = 0;
    draining_ = false;
    return true;
}

// 关闭解码器并释放 FFmpeg 上下文与缓冲区。
void Decoder::close() {
    if (swrCtx_) {
        swr_free(&swrCtx_);
    }
    if (codecCtx_) {
        avcodec_free_context(&codecCtx_);
    }
    if (fmtCtx_) {
        avformat_close_input(&fmtCtx_);
    }
    audioStreamIndex_ = -1;
    isOpen_ = false;
    decodedBuf_.clear();
    decodedBufPos_ = 0;
    decodedBufFrames_ = 0;
    coverArtData_.clear();
    draining_ = false;
}

// 查询解码器是否处于打开状态。
bool Decoder::isOpen() const {
    return isOpen_;
}

// 尝试从解码器接收已解码帧并转换为浮点格式。
bool Decoder::receiveDecodedFrame() {
    const int ret = avcodec_receive_frame(codecCtx_, frame_);
    if (ret == 0) {
        return convertCurrentFrame();
    }
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
        return false;
    }

    lastError_ = "Failed to decode audio frame: " + ffmpegErrorString(ret);
    return false;
}

// 将当前解码帧转换为浮点交错音频数据。
bool Decoder::convertCurrentFrame() {
    const int outSamples = frame_->nb_samples;
    const int ch = format_.channels;
    decodedBuf_.resize(outSamples * ch);

    uint8_t* outBuf = reinterpret_cast<uint8_t*>(decodedBuf_.data());
    const uint8_t** inBuf = const_cast<const uint8_t**>(frame_->extended_data);

    const int converted = swr_convert(swrCtx_, &outBuf, outSamples, inBuf, frame_->nb_samples);
    if (converted < 0) {
        lastError_ = "Failed to convert audio samples: " + ffmpegErrorString(converted);
        av_frame_unref(frame_);
        return false;
    }

    decodedBufFrames_ = converted;
    decodedBufPos_ = 0;

    if (frame_->best_effort_timestamp != AV_NOPTS_VALUE) {
        auto* stream = fmtCtx_->streams[audioStreamIndex_];
        currentPts_ = av_rescale_q(frame_->best_effort_timestamp, stream->time_base, AVRational{1, 1000});
    }

    av_frame_unref(frame_);
    return true;
}

// 读取下一个数据包并解码，直到生成可用音频帧。
bool Decoder::decodeNextFrame() {
    while (true) {
        if (receiveDecodedFrame()) {
            return true;
        }

        const int ret = av_read_frame(fmtCtx_, packet_);
        if (ret < 0) {
            if (draining_) {
                return false;
            }

            draining_ = true;
            const int flushRet = avcodec_send_packet(codecCtx_, nullptr);
            if (flushRet < 0 && flushRet != AVERROR_EOF) {
                lastError_ = "Failed to flush decoder: " + ffmpegErrorString(flushRet);
            }
            continue;
        }

        draining_ = false;
        if (packet_->stream_index != audioStreamIndex_) {
            av_packet_unref(packet_);
            continue;
        }

        const int sendRet = avcodec_send_packet(codecCtx_, packet_);
        av_packet_unref(packet_);
        if (sendRet == AVERROR(EAGAIN)) {
            continue;
        }
        if (sendRet < 0) {
            lastError_ = "Failed to send packet to decoder: " + ffmpegErrorString(sendRet);
            return false;
        }
    }
}

// 从解码缓冲区读取最多 maxFrames 帧，返回实际读取帧数。
int Decoder::read(AudioBuffer& buffer, int maxFrames) {
    if (!isOpen_) return -1;

    buffer.channels = format_.channels;
    buffer.sampleRate = format_.sampleRate;
    buffer.data.clear();
    buffer.data.reserve(maxFrames * format_.channels);

    int framesRead = 0;
    while (framesRead < maxFrames) {
        // 使用剩余解码数据
        if (decodedBufPos_ < decodedBufFrames_) {
            int available = decodedBufFrames_ - decodedBufPos_;
            int toRead = std::min(available, maxFrames - framesRead);
            int offset = decodedBufPos_ * format_.channels;
            buffer.data.insert(buffer.data.end(),
                decodedBuf_.begin() + offset,
                decodedBuf_.begin() + offset + toRead * format_.channels);
            decodedBufPos_ += toRead;
            framesRead += toRead;
        } else {
            // 继续解码
            if (!decodeNextFrame()) break; // 文件末尾
        }
    }
    return framesRead;
}

// 跳转到指定毫秒位置并刷新解码缓存。
bool Decoder::seek(int64_t positionMs) {
    if (!isOpen_) return false;
    auto* stream = fmtCtx_->streams[audioStreamIndex_];
    int64_t ts = av_rescale_q(positionMs, {1, 1000}, stream->time_base);
    if (av_seek_frame(fmtCtx_, audioStreamIndex_, ts, AVSEEK_FLAG_BACKWARD) < 0)
        return false;
    avcodec_flush_buffers(codecCtx_);
    decodedBufPos_ = 0;
    decodedBufFrames_ = 0;
    currentPts_ = positionMs;
    draining_ = false;
    return true;
}

// 返回当前音频文件的总时长（毫秒）。
int64_t Decoder::durationMs() const {
    if (!isOpen_ || !fmtCtx_) return 0;
    if (fmtCtx_->duration > 0)
        return fmtCtx_->duration / (AV_TIME_BASE / 1000);
    return 0;
}

// 返回当前解码位置时间戳（毫秒）。
int64_t Decoder::positionMs() const {
    return currentPts_;
}

// 获取当前音频文件的 title 元数据。
std::string Decoder::title() const {
    if (!fmtCtx_) return {};
    AVDictionaryEntry* tag = av_dict_get(fmtCtx_->metadata, "title", nullptr, 0);
    return tag ? tag->value : std::string{};
}

// 获取当前音频文件的 artist 元数据。
std::string Decoder::artist() const {
    if (!fmtCtx_) return {};
    AVDictionaryEntry* tag = av_dict_get(fmtCtx_->metadata, "artist", nullptr, 0);
    return tag ? tag->value : std::string{};
}

// 获取当前音频文件的 album 元数据。
std::string Decoder::album() const {
    if (!fmtCtx_) return {};
    AVDictionaryEntry* tag = av_dict_get(fmtCtx_->metadata, "album", nullptr, 0);
    return tag ? tag->value : std::string{};
}
