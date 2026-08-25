#pragma once

// Windows: open local files via CreateFileW so UTF-8 (and ACP fallback) paths
// work. avformat_open_input otherwise depends on FFmpeg's UTF-8 conversion
// plus a CP_ACP fallback that never runs if the bytes are valid-but-wrong UTF-8.

extern "C" {
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
}

#include <cerrno>
#include <cstring>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

struct Utf8Avio {
#ifdef _WIN32
    HANDLE handle = INVALID_HANDLE_VALUE;
#else
    void* handle = nullptr;
#endif
    AVIOContext* avio = nullptr;

    Utf8Avio() = default;
    Utf8Avio(const Utf8Avio&) = delete;
    Utf8Avio& operator=(const Utf8Avio&) = delete;

    void close() {
        if (avio) {
            avio_context_free(&avio);
        }
#ifdef _WIN32
        if (handle != INVALID_HANDLE_VALUE) {
            CloseHandle(handle);
            handle = INVALID_HANDLE_VALUE;
        }
#else
        handle = nullptr;
#endif
    }

    ~Utf8Avio() { close(); }
};

#ifdef _WIN32
inline int utf8AvioRead(void* opaque, uint8_t* buf, int bufSize) {
    auto* h = static_cast<HANDLE>(opaque);
    DWORD n = 0;
    if (bufSize <= 0) {
        return AVERROR(EINVAL);
    }
    if (!ReadFile(h, buf, static_cast<DWORD>(bufSize), &n, nullptr)) {
        return AVERROR(EIO);
    }
    if (n == 0) {
        return AVERROR_EOF;
    }
    return static_cast<int>(n);
}

inline int64_t utf8AvioSeek(void* opaque, int64_t offset, int whence) {
    auto* h = static_cast<HANDLE>(opaque);
    if (whence == AVSEEK_SIZE) {
        LARGE_INTEGER sz{};
        if (!GetFileSizeEx(h, &sz)) {
            return AVERROR(EIO);
        }
        return sz.QuadPart;
    }
    DWORD method = FILE_BEGIN;
    if (whence == SEEK_CUR) {
        method = FILE_CURRENT;
    } else if (whence == SEEK_END) {
        method = FILE_END;
    } else if (whence != SEEK_SET) {
        return AVERROR(EINVAL);
    }
    LARGE_INTEGER in{};
    LARGE_INTEGER out{};
    in.QuadPart = offset;
    if (!SetFilePointerEx(h, in, &out, method)) {
        return AVERROR(EIO);
    }
    return out.QuadPart;
}

inline HANDLE openUtf8ReadHandle(const char* pathUtf8) {
    if (!pathUtf8 || !*pathUtf8) {
        return INVALID_HANDLE_VALUE;
    }
    wchar_t wbuf[32768];
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, pathUtf8, -1, wbuf, 32768);
    if (n <= 0) {
        n = MultiByteToWideChar(CP_ACP, 0, pathUtf8, -1, wbuf, 32768);
    }
    if (n <= 0) {
        return INVALID_HANDLE_VALUE;
    }

    HANDLE h = CreateFileW(
        wbuf, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
        return h;
    }
    if (n + 4 > 32768) {
        return INVALID_HANDLE_VALUE;
    }
    if (wbuf[0] == L'\\' && wbuf[1] == L'\\') {
        return INVALID_HANDLE_VALUE;
    }
    wchar_t ext[32768];
    ext[0] = L'\\';
    ext[1] = L'\\';
    ext[2] = L'?';
    ext[3] = L'\\';
    std::memcpy(ext + 4, wbuf, static_cast<size_t>(n) * sizeof(wchar_t));
    return CreateFileW(
        ext, GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
}
#endif

inline int avformatOpenUtf8(AVFormatContext** ctx, const char* pathUtf8, Utf8Avio* io) {
    if (!ctx) {
        return AVERROR(EINVAL);
    }
    *ctx = nullptr;
#ifdef _WIN32
    HANDLE h = openUtf8ReadHandle(pathUtf8);
    if (h != INVALID_HANDLE_VALUE) {
        unsigned char* buf = static_cast<unsigned char*>(av_malloc(65536));
        if (!buf) {
            CloseHandle(h);
            return AVERROR(ENOMEM);
        }
        AVIOContext* avio = avio_alloc_context(
            buf, 65536, 0, h, utf8AvioRead, nullptr, utf8AvioSeek);
        if (!avio) {
            av_free(buf);
            CloseHandle(h);
            return AVERROR(ENOMEM);
        }
        AVFormatContext* fmt = avformat_alloc_context();
        if (!fmt) {
            avio_context_free(&avio);
            CloseHandle(h);
            return AVERROR(ENOMEM);
        }
        fmt->pb = avio;
        fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
        const int ret = avformat_open_input(&fmt, pathUtf8, nullptr, nullptr);
        if (ret < 0) {
            if (fmt) {
                fmt->pb = nullptr;
                avformat_free_context(fmt);
            }
            avio_context_free(&avio);
            CloseHandle(h);
            return ret;
        }
        *ctx = fmt;
        if (io) {
            io->handle = h;
            io->avio = avio;
        }
        return 0;
    }
#endif
    return avformat_open_input(ctx, pathUtf8, nullptr, nullptr);
}

inline void avformatCloseUtf8(AVFormatContext** ctx, Utf8Avio* io) {
    if (ctx && *ctx && io && io->avio) {
        (*ctx)->pb = nullptr;
    }
    if (ctx && *ctx) {
        avformat_close_input(ctx);
    }
    if (io) {
        io->close();
    }
}
