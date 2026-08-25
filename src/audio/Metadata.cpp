#include "Metadata.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/dict.h>
}

namespace {

#ifdef _WIN32
std::wstring utf8ToWide(const char* s) {
    if (!s || !*s) {
        return {};
    }
    const int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (n <= 1) {
        return {};
    }
    std::wstring w(static_cast<size_t>(n - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w.data(), n);
    return w;
}
#endif

FILE* openUtf8(const char* path, const char* mode) {
#ifdef _WIN32
    const std::wstring wpath = utf8ToWide(path);
    if (wpath.empty()) {
        return nullptr;
    }
    wchar_t wmode[8] = {};
    for (int i = 0; mode[i] && i < 7; ++i) {
        wmode[i] = static_cast<wchar_t>(mode[i]);
    }
    return _wfopen(wpath.c_str(), wmode);
#else
    return std::fopen(path, mode);
#endif
}

bool readAllBytes(const char* path, std::vector<unsigned char>& out) {
    out.clear();
    FILE* f = openUtf8(path, "rb");
    if (!f) {
        return false;
    }
    if (std::fseek(f, 0, SEEK_END) != 0) {
        std::fclose(f);
        return false;
    }
    const long sz = std::ftell(f);
    if (sz < 12) {
        std::fclose(f);
        return false;
    }
    if (std::fseek(f, 0, SEEK_SET) != 0) {
        std::fclose(f);
        return false;
    }
    out.resize(static_cast<size_t>(sz));
    const size_t n = std::fread(out.data(), 1, static_cast<size_t>(sz), f);
    std::fclose(f);
    if (n != static_cast<size_t>(sz)) {
        out.clear();
        return false;
    }
    return true;
}

bool writeAllBytes(const char* path, const std::vector<unsigned char>& data) {
    FILE* f = openUtf8(path, "wb");
    if (!f) {
        return false;
    }
    const size_t n = std::fwrite(data.data(), 1, data.size(), f);
    const int err = std::fclose(f);
    return n == data.size() && err == 0;
}

bool replaceFile(const std::string& from, const char* to) {
#ifdef _WIN32
    const std::wstring wfrom = utf8ToWide(from.c_str());
    const std::wstring wto = utf8ToWide(to);
    if (wfrom.empty() || wto.empty()) {
        return false;
    }
    return MoveFileExW(wfrom.c_str(), wto.c_str(),
                       MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
    if (std::rename(from.c_str(), to) == 0) {
        return true;
    }
    std::remove(to);
    return std::rename(from.c_str(), to) == 0;
#endif
}

void removeUtf8(const char* path) {
#ifdef _WIN32
    const std::wstring w = utf8ToWide(path);
    if (!w.empty()) {
        DeleteFileW(w.c_str());
    }
#else
    std::remove(path);
#endif
}

uint32_t readU32le(const unsigned char* p) {
    return static_cast<uint32_t>(p[0])
        | (static_cast<uint32_t>(p[1]) << 8)
        | (static_cast<uint32_t>(p[2]) << 16)
        | (static_cast<uint32_t>(p[3]) << 24);
}

void appendU32le(std::vector<unsigned char>& out, uint32_t v) {
    out.push_back(static_cast<unsigned char>(v & 0xffu));
    out.push_back(static_cast<unsigned char>((v >> 8) & 0xffu));
    out.push_back(static_cast<unsigned char>((v >> 16) & 0xffu));
    out.push_back(static_cast<unsigned char>((v >> 24) & 0xffu));
}

void appendFour(std::vector<unsigned char>& out, const char id[4]) {
    out.insert(out.end(), id, id + 4);
}

void appendInfoTag(std::vector<unsigned char>& info, const char id[4], const char* value) {
    if (!value) {
        value = "";
    }
    const uint32_t n = static_cast<uint32_t>(std::strlen(value) + 1);
    appendFour(info, id);
    appendU32le(info, n);
    info.insert(info.end(), value, value + n);
    if (n & 1u) {
        info.push_back(0);
    }
}

bool looksLikeWav(const std::vector<unsigned char>& bytes) {
    return bytes.size() >= 12
        && std::memcmp(bytes.data(), "RIFF", 4) == 0
        && std::memcmp(bytes.data() + 8, "WAVE", 4) == 0;
}

bool writeWavInfoTags(const char* path,
                      const char* title,
                      const char* artist,
                      const char* album) {
    std::vector<unsigned char> bytes;
    if (!readAllBytes(path, bytes) || !looksLikeWav(bytes)) {
        return false;
    }

    std::vector<unsigned char> kept;
    kept.reserve(bytes.size() + 128);
    size_t off = 12;
    while (off + 8 <= bytes.size()) {
        const unsigned char* id = bytes.data() + off;
        const uint32_t sz = readU32le(bytes.data() + off + 4);
        const size_t dataOff = off + 8;
        const size_t dataEnd = dataOff + static_cast<size_t>(sz);
        if (dataEnd > bytes.size()) {
            break;
        }
        const bool isInfoList = std::memcmp(id, "LIST", 4) == 0
            && sz >= 4
            && std::memcmp(bytes.data() + dataOff, "INFO", 4) == 0;
        if (!isInfoList) {
            kept.insert(kept.end(), bytes.begin() + static_cast<std::ptrdiff_t>(off),
                        bytes.begin() + static_cast<std::ptrdiff_t>(dataEnd));
            if (sz & 1u) {
                if (dataEnd < bytes.size()) {
                    kept.push_back(bytes[dataEnd]);
                } else {
                    kept.push_back(0);
                }
            }
        }
        off = dataEnd + ((sz & 1u) ? 1 : 0);
    }

    std::vector<unsigned char> info;
    appendFour(info, "INFO");
    appendInfoTag(info, "INAM", title);
    appendInfoTag(info, "IART", artist);
    appendInfoTag(info, "IPRD", album);

    std::vector<unsigned char> out;
    out.reserve(12 + kept.size() + 8 + info.size());
    appendFour(out, "RIFF");
    appendU32le(out, 0);
    appendFour(out, "WAVE");
    out.insert(out.end(), kept.begin(), kept.end());
    appendFour(out, "LIST");
    appendU32le(out, static_cast<uint32_t>(info.size()));
    out.insert(out.end(), info.begin(), info.end());
    if (info.size() & 1u) {
        out.push_back(0);
    }
    const uint32_t riffSize = static_cast<uint32_t>(out.size() - 8);
    out[4] = static_cast<unsigned char>(riffSize & 0xffu);
    out[5] = static_cast<unsigned char>((riffSize >> 8) & 0xffu);
    out[6] = static_cast<unsigned char>((riffSize >> 16) & 0xffu);
    out[7] = static_cast<unsigned char>((riffSize >> 24) & 0xffu);

    const std::string tmp = std::string(path) + ".ttmeta.tmp";
    if (!writeAllBytes(tmp.c_str(), out)) {
        removeUtf8(tmp.c_str());
        return false;
    }
    if (!replaceFile(tmp, path)) {
        removeUtf8(tmp.c_str());
        return false;
    }
    return true;
}

const char* dictValue(const AVDictionary* d, const char* key) {
    if (!d || !key) {
        return nullptr;
    }
    const AVDictionaryEntry* e = av_dict_get(d, key, nullptr, 0);
    if (e && e->value && e->value[0] != '\0') {
        return e->value;
    }
    return nullptr;
}

bool remuxWithMetadata(const char* pathUtf8,
                       const char* titleUtf8,
                       const char* artistUtf8,
                       const char* albumUtf8) {
    AVFormatContext* in = nullptr;
    if (avformat_open_input(&in, pathUtf8, nullptr, nullptr) < 0) {
        return false;
    }
    if (avformat_find_stream_info(in, nullptr) < 0) {
        avformat_close_input(&in);
        return false;
    }

    const AVOutputFormat* ofmt = av_guess_format(nullptr, pathUtf8, nullptr);
    if (!ofmt && in->iformat) {
        ofmt = av_guess_format(in->iformat->name, nullptr, nullptr);
    }

    const std::string tmp = std::string(pathUtf8) + ".ttmeta.tmp";
    AVFormatContext* out = nullptr;
    if (avformat_alloc_output_context2(&out, ofmt, ofmt ? ofmt->name : nullptr, tmp.c_str()) < 0
        || !out) {
        avformat_close_input(&in);
        return false;
    }

    bool headerWritten = false;
    bool ok = false;
    AVPacket* pkt = av_packet_alloc();
    if (!pkt) {
        goto cleanup;
    }

    av_dict_copy(&out->metadata, in->metadata, 0);
    av_dict_set(&out->metadata, "title", titleUtf8 ? titleUtf8 : "", 0);
    av_dict_set(&out->metadata, "artist", artistUtf8 ? artistUtf8 : "", 0);
    av_dict_set(&out->metadata, "album", albumUtf8 ? albumUtf8 : "", 0);

    for (unsigned i = 0; i < in->nb_streams; ++i) {
        AVStream* inSt = in->streams[i];
        AVStream* outSt = avformat_new_stream(out, nullptr);
        if (!outSt || avcodec_parameters_copy(outSt->codecpar, inSt->codecpar) < 0) {
            goto cleanup;
        }
        outSt->time_base = inSt->time_base;
        outSt->disposition = inSt->disposition;
        av_dict_copy(&outSt->metadata, inSt->metadata, 0);
        if (inSt->codecpar && inSt->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            av_dict_set(&outSt->metadata, "title", titleUtf8 ? titleUtf8 : "", 0);
            av_dict_set(&outSt->metadata, "artist", artistUtf8 ? artistUtf8 : "", 0);
            av_dict_set(&outSt->metadata, "album", albumUtf8 ? albumUtf8 : "", 0);
        }
    }

    if (!(out->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&out->pb, tmp.c_str(), AVIO_FLAG_WRITE) < 0) {
            goto cleanup;
        }
    }
    if (avformat_write_header(out, nullptr) < 0) {
        goto cleanup;
    }
    headerWritten = true;

    while (av_read_frame(in, pkt) >= 0) {
        if (pkt->stream_index < 0
            || static_cast<unsigned>(pkt->stream_index) >= out->nb_streams) {
            av_packet_unref(pkt);
            continue;
        }
        AVStream* inSt = in->streams[pkt->stream_index];
        AVStream* outSt = out->streams[pkt->stream_index];
        av_packet_rescale_ts(pkt, inSt->time_base, outSt->time_base);
        pkt->pos = -1;
        const int w = av_interleaved_write_frame(out, pkt);
        av_packet_unref(pkt);
        if (w < 0) {
            goto cleanup;
        }
    }

    if (av_write_trailer(out) < 0) {
        goto cleanup;
    }
    headerWritten = false;
    ok = true;

cleanup:
    if (pkt) {
        av_packet_free(&pkt);
    }
    if (out) {
        if (headerWritten) {
            av_write_trailer(out);
        }
        if (out->pb) {
            avio_closep(&out->pb);
        }
        avformat_free_context(out);
    }
    avformat_close_input(&in);
    if (!ok) {
        removeUtf8(tmp.c_str());
        return false;
    }
    if (!replaceFile(tmp, pathUtf8)) {
        removeUtf8(tmp.c_str());
        return false;
    }
    return true;
}

} // namespace

std::string audioMetadataField(const AVFormatContext* fmt, const char* key) {
    if (!fmt || !key) {
        return {};
    }
    if (const char* v = dictValue(fmt->metadata, key)) {
        return v;
    }
    const int audio = av_find_best_stream(
        const_cast<AVFormatContext*>(fmt), AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (audio >= 0) {
        if (const char* v = dictValue(fmt->streams[audio]->metadata, key)) {
            return v;
        }
    }
    for (unsigned i = 0; i < fmt->nb_streams; ++i) {
        if (const char* v = dictValue(fmt->streams[i]->metadata, key)) {
            return v;
        }
    }
    return {};
}

int64_t audioDurationMs(const AVFormatContext* fmt) {
    if (!fmt) {
        return 0;
    }
    if (fmt->duration > 0 && fmt->duration != AV_NOPTS_VALUE) {
        return fmt->duration / (AV_TIME_BASE / 1000);
    }
    const int audio = av_find_best_stream(
        const_cast<AVFormatContext*>(fmt), AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (audio >= 0) {
        const AVStream* st = fmt->streams[audio];
        if (st->duration > 0 && st->duration != AV_NOPTS_VALUE) {
            return av_rescale_q(st->duration, st->time_base, AVRational{1, 1000});
        }
    }
    return 0;
}

bool readAudioFileMetadata(const char* pathUtf8, AudioFileMetadata& out) {
    out = {};
    if (!pathUtf8 || !*pathUtf8) {
        return false;
    }
    AVFormatContext* fmt = nullptr;
    if (avformat_open_input(&fmt, pathUtf8, nullptr, nullptr) < 0) {
        return false;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        avformat_close_input(&fmt);
        return false;
    }
    out.title = audioMetadataField(fmt, "title");
    out.artist = audioMetadataField(fmt, "artist");
    out.album = audioMetadataField(fmt, "album");
    out.duration_ms = audioDurationMs(fmt);
    avformat_close_input(&fmt);
    return true;
}

bool writeAudioFileMetadata(const char* pathUtf8,
                            const char* titleUtf8,
                            const char* artistUtf8,
                            const char* albumUtf8) {
    if (!pathUtf8 || !*pathUtf8) {
        return false;
    }
    std::vector<unsigned char> probe;
    if (readAllBytes(pathUtf8, probe) && looksLikeWav(probe)) {
        return writeWavInfoTags(pathUtf8, titleUtf8, artistUtf8, albumUtf8);
    }
    return remuxWithMetadata(pathUtf8, titleUtf8, artistUtf8, albumUtf8);
}
