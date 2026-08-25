#include "ttcore.h"

#include "Decoder.h"
#include "DspChain.h"
#include "AudioOutput.h"
#include "Metadata.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

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

std::string basenameUtf8(const std::string& path) {
    const auto slash = path.find_last_of("/\\");
    std::string name = (slash == std::string::npos) ? path : path.substr(slash + 1);
    const auto dot = name.find_last_of('.');
    if (dot != std::string::npos && dot > 0) {
        name.resize(dot);
    }
    return name;
}

std::string parentDirUtf8(const std::string& path) {
    const auto slash = path.find_last_of("/\\");
    if (slash == std::string::npos) {
        return ".";
    }
    if (slash == 0) {
        return path.substr(0, 1);
    }
    return path.substr(0, slash);
}

std::string joinUtf8(const std::string& dir, const std::string& name) {
    if (dir.empty()) {
        return name;
    }
    const char last = dir.back();
    if (last == '/' || last == '\\') {
        return dir + name;
    }
    return dir + '/' + name;
}

bool readAllBytes(const std::string& path, std::vector<unsigned char>& out) {
    if (path.empty()) {
        return false;
    }
#ifdef _WIN32
    const std::wstring wide = utf8ToWide(path.c_str());
    if (wide.empty()) {
        return false;
    }
    FILE* f = _wfopen(wide.c_str(), L"rb");
#else
    FILE* f = std::fopen(path.c_str(), "rb");
#endif
    if (!f) {
        return false;
    }
    if (std::fseek(f, 0, SEEK_END) != 0) {
        std::fclose(f);
        return false;
    }
    const long sz = std::ftell(f);
    if (sz <= 0) {
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

void loadSidecarCover(const std::string& audioPath, std::vector<unsigned char>& out) {
    out.clear();
    if (audioPath.empty()) {
        return;
    }
    const std::string dir = parentDirUtf8(audioPath);
    const std::string stem = basenameUtf8(audioPath);
    const std::string stemCandidates[] = {
        stem + ".jpg",
        stem + ".jpeg",
        stem + ".png"
    };
    for (const auto& name : stemCandidates) {
        if (readAllBytes(joinUtf8(dir, name), out)) {
            return;
        }
    }
    static const char* kFixed[] = {
        "cover.jpg", "cover.jpeg", "cover.png",
        "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.jpeg", "front.png",
        "album.jpg", "album.jpeg", "album.png"
    };
    for (const char* name : kFixed) {
        if (readAllBytes(joinUtf8(dir, name), out)) {
            return;
        }
    }
    out.clear();
}

void copyUtf8Field(char* dst, size_t cap, const std::string& src) {
    if (!dst || cap == 0) {
        return;
    }
    const size_t n = std::min(cap - 1, src.size());
    std::memcpy(dst, src.data(), n);
    dst[n] = '\0';
}

class PlayerCore {
public:
    PlayerCore() {
        spectrumBuf_.assign(1024, 0.0f);
    }

    ~PlayerCore() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            progressCb_ = nullptr;
            finishedCb_ = nullptr;
            errorCb_ = nullptr;
            progressUd_ = nullptr;
            finishedUd_ = nullptr;
            errorUd_ = nullptr;
        }
        output_.pause();
        output_.close();
        std::lock_guard<std::mutex> lock(mutex_);
        decoder_.close();
    }

    bool open(const char* pathUtf8) {
        if (!pathUtf8 || !*pathUtf8) {
            fireError("Failed to open: empty path");
            return false;
        }

        output_.pause();

        std::unique_lock<std::mutex> lock(mutex_);
        decoder_.close();
        state_ = TTCORE_STOPPED;
        hasFile_ = false;
        currentFile_.clear();
        title_.clear();
        artist_.clear();
        album_.clear();
        cover_.clear();
        lastError_.clear();

        if (!decoder_.open(pathUtf8)) {
            lastError_ = decoder_.lastError();
            if (lastError_.empty()) {
                lastError_ = std::string("Failed to open: ") + pathUtf8;
            }
            const std::string err = lastError_;
            lock.unlock();
            fireError(err.c_str());
            return false;
        }

        currentFile_ = pathUtf8;
        hasFile_ = true;
        title_ = decoder_.title();
        artist_ = decoder_.artist();
        album_ = decoder_.album();
        if (title_.empty()) {
            title_ = basenameUtf8(currentFile_);
        }

        cover_ = decoder_.coverArtData();
        if (cover_.empty()) {
            loadSidecarCover(currentFile_, cover_);
        }

        const auto fmt = decoder_.format();
        dsp_.setSampleRate(fmt.sampleRate);
        dsp_.equalizer.setSampleRate(fmt.sampleRate);

        auto cb = [this](float* buf, int frames) { audioCallback(buf, frames); };
        // Always open stereo: many devices reject mono (the test fixture and some
        // MP3s) when SDL is not allowed to change the channel count.
        const int outChannels = 2;
        if (fmt.sampleRate < 8000 || fmt.sampleRate > 384000) {
            decoder_.close();
            hasFile_ = false;
            currentFile_.clear();
            cover_.clear();
            lastError_ = "Invalid sample rate: " + std::to_string(fmt.sampleRate);
            const std::string err = lastError_;
            lock.unlock();
            fireError(err.c_str());
            return false;
        }

        if (!output_.open(fmt.sampleRate, outChannels, cb)) {
            decoder_.close();
            hasFile_ = false;
            currentFile_.clear();
            cover_.clear();
            lastError_ = "Failed to open audio output";
            if (!output_.lastError().empty()) {
                lastError_ += ": " + output_.lastError();
            }
            const std::string err = lastError_;
            lock.unlock();
            fireError(err.c_str());
            return false;
        }

        return true;
    }

    void play() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!decoder_.isOpen()) {
            return;
        }
        output_.start();
        state_ = TTCORE_PLAYING;
    }

    void pause() {
        std::lock_guard<std::mutex> lock(mutex_);
        output_.pause();
        if (state_ == TTCORE_PLAYING) {
            state_ = TTCORE_PAUSED;
        }
    }

    void stop() {
        output_.pause();
        output_.close();
        std::lock_guard<std::mutex> lock(mutex_);
        decoder_.close();
        hasFile_ = false;
        currentFile_.clear();
        title_.clear();
        artist_.clear();
        album_.clear();
        cover_.clear();
        state_ = TTCORE_STOPPED;
    }

    void seek(int64_t positionMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (decoder_.isOpen()) {
            decoder_.seek(positionMs);
        }
    }

    ttcore_state state() const { return state_.load(); }

    int64_t positionMs() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return decoder_.positionMs();
    }

    int64_t durationMs() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return decoder_.durationMs();
    }

    bool hasFile() const { return hasFile_.load(); }

    const char* lastError() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return threadSnap(lastError_);
    }

    void setVolume(int volume) {
        const int clamped = std::clamp(volume, 0, 100);
        dsp_.setVolume(clamped / 100.0f);
    }

    int volume() const {
        return static_cast<int>(dsp_.volume() * 100.0f + 0.5f);
    }

    void setMuted(bool m) { dsp_.setMuted(m); }
    bool isMuted() const { return dsp_.isMuted(); }

    void setEqEnabled(bool enabled) { dsp_.equalizer.setEnabled(enabled); }
    bool eqEnabled() const { return dsp_.equalizer.isEnabled(); }

    void setEqGain(int band, double gainDb) { dsp_.equalizer.setBandGain(band, gainDb); }
    double eqGain(int band) const { return dsp_.equalizer.bandGain(band); }

    void setPreamp(double gainDb) { dsp_.equalizer.setPreamp(gainDb); }
    double preamp() const { return dsp_.equalizer.preamp(); }

    void setBalance(int balance) {
        dsp_.setBalance(std::clamp(balance, -100, 100) / 100.0f);
    }

    int balance() const {
        return static_cast<int>(std::lround(static_cast<double>(dsp_.balance()) * 100.0));
    }

    const char* title() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return threadSnap(title_);
    }
    const char* artist() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return threadSnap(artist_);
    }
    const char* album() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return threadSnap(album_);
    }

    int getSpectrum(float* out, int count) const {
        if (!out || count <= 0) {
            return 0;
        }
        std::lock_guard<std::mutex> lock(spectrumMutex_);
        const int n = std::min(count, static_cast<int>(spectrumBuf_.size()));
        std::memcpy(out, spectrumBuf_.data(), static_cast<size_t>(n) * sizeof(float));
        return n;
    }

    int getCover(unsigned char* out, int cap) const {
        std::lock_guard<std::mutex> lock(mutex_);
        const int n = static_cast<int>(cover_.size());
        if (out && cap > 0 && n > 0) {
            const int copy = std::min(n, cap);
            std::memcpy(out, cover_.data(), static_cast<size_t>(copy));
        }
        return n;
    }

    void setProgressCallback(ttcore_progress_cb cb, void* userdata) {
        std::lock_guard<std::mutex> lock(mutex_);
        progressCb_ = cb;
        progressUd_ = userdata;
    }

    void setFinishedCallback(ttcore_finished_cb cb, void* userdata) {
        std::lock_guard<std::mutex> lock(mutex_);
        finishedCb_ = cb;
        finishedUd_ = userdata;
    }

    void setErrorCallback(ttcore_error_cb cb, void* userdata) {
        std::lock_guard<std::mutex> lock(mutex_);
        errorCb_ = cb;
        errorUd_ = userdata;
    }

private:
    static const char* threadSnap(const std::string& s) {
        thread_local std::string snap;
        snap = s;
        return snap.c_str();
    }

    void fireError(const char* message) {
        std::string err = message ? message : "";
        ttcore_error_cb cb = nullptr;
        void* ud = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            lastError_ = err;
            cb = errorCb_;
            ud = errorUd_;
        }
        if (cb) {
            cb(ud, err.c_str());
        }
    }

    static void remixFrames(const float* src, int srcCh, int frames,
                            float* dst, int dstCh, int dstFrames) {
        const int n = std::min(frames, dstFrames);
        if (srcCh <= 0) {
            srcCh = 1;
        }
        if (dstCh <= 0) {
            dstCh = 1;
        }
        for (int i = 0; i < n; ++i) {
            if (srcCh == dstCh) {
                std::memcpy(dst + i * dstCh, src + i * srcCh,
                            static_cast<size_t>(dstCh) * sizeof(float));
                continue;
            }
            if (srcCh == 1) {
                const float s = src[i];
                for (int c = 0; c < dstCh; ++c) {
                    dst[i * dstCh + c] = s;
                }
                continue;
            }
            if (dstCh == 1) {
                dst[i] = 0.5f * (src[i * srcCh] + src[i * srcCh + 1]);
                continue;
            }
            dst[i * dstCh] = src[i * srcCh];
            dst[i * dstCh + 1] = src[i * srcCh + 1];
            for (int c = 2; c < dstCh; ++c) {
                dst[i * dstCh + c] = 0.0f;
            }
        }
        if (n < dstFrames) {
            std::memset(dst + n * dstCh, 0,
                        static_cast<size_t>(dstFrames - n) * dstCh * sizeof(float));
        }
    }

    void audioCallback(float* buffer, int frames) {
        std::unique_lock<std::mutex> lock(mutex_);
        const int ch = output_.channels();
        const int outputSamples = frames * ch;
        if (state_ != TTCORE_PLAYING || !decoder_.isOpen()) {
            std::memset(buffer, 0, static_cast<size_t>(outputSamples) * sizeof(float));
            return;
        }

        AudioBuffer abuf;
        const int read = decoder_.read(abuf, frames);
        if (read <= 0) {
            std::memset(buffer, 0, static_cast<size_t>(outputSamples) * sizeof(float));
            if (read == 0) {
                state_ = TTCORE_STOPPED;
                auto cb = finishedCb_;
                auto ud = finishedUd_;
                lock.unlock();
                if (cb) {
                    cb(ud);
                }
            }
            return;
        }

        {
            std::lock_guard<std::mutex> slock(spectrumMutex_);
            const int n = std::min(read, static_cast<int>(spectrumBuf_.size()));
            const int srcCh = std::max(1, abuf.channels);
            for (int i = 0; i < n; ++i) {
                spectrumBuf_[static_cast<size_t>(i)] = abuf.data[static_cast<size_t>(i * srcCh)];
            }
        }

        dsp_.process(abuf.data.data(), read, abuf.channels);

        remixFrames(abuf.data.data(), abuf.channels, read, buffer, ch, frames);

        const int64_t pos = decoder_.positionMs();
        auto cb = progressCb_;
        auto ud = progressUd_;
        lock.unlock();
        if (cb) {
            cb(ud, pos);
        }
    }

    Decoder decoder_;
    DspChain dsp_;
    AudioOutput output_;

    mutable std::mutex mutex_;
    std::atomic<ttcore_state> state_{TTCORE_STOPPED};
    std::atomic<bool> hasFile_{false};
    std::string currentFile_;
    std::string title_;
    std::string artist_;
    std::string album_;
    std::vector<unsigned char> cover_;
    std::string lastError_;

    mutable std::mutex spectrumMutex_;
    std::vector<float> spectrumBuf_;

    ttcore_progress_cb progressCb_ = nullptr;
    void* progressUd_ = nullptr;
    ttcore_finished_cb finishedCb_ = nullptr;
    void* finishedUd_ = nullptr;
    ttcore_error_cb errorCb_ = nullptr;
    void* errorUd_ = nullptr;
};

PlayerCore* asPlayer(ttcore_player player) {
    return static_cast<PlayerCore*>(player);
}

} // namespace

extern "C" {

ttcore_player TTCORE_CALL ttcore_create(void) {
    try {
        return new PlayerCore();
    } catch (...) {
        return nullptr;
    }
}

void TTCORE_CALL ttcore_destroy(ttcore_player player) {
    delete asPlayer(player);
}

int TTCORE_CALL ttcore_open(ttcore_player player, const char* path_utf8) {
    auto* p = asPlayer(player);
    if (!p) {
        return 0;
    }
    return p->open(path_utf8) ? 1 : 0;
}

void TTCORE_CALL ttcore_play(ttcore_player player) {
    if (auto* p = asPlayer(player)) {
        p->play();
    }
}

void TTCORE_CALL ttcore_pause(ttcore_player player) {
    if (auto* p = asPlayer(player)) {
        p->pause();
    }
}

void TTCORE_CALL ttcore_stop(ttcore_player player) {
    if (auto* p = asPlayer(player)) {
        p->stop();
    }
}

void TTCORE_CALL ttcore_seek(ttcore_player player, int64_t position_ms) {
    if (auto* p = asPlayer(player)) {
        p->seek(position_ms);
    }
}

ttcore_state TTCORE_CALL ttcore_get_state(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->state() : TTCORE_STOPPED;
}

int64_t TTCORE_CALL ttcore_get_position_ms(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->positionMs() : 0;
}

int64_t TTCORE_CALL ttcore_get_duration_ms(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->durationMs() : 0;
}

const char* TTCORE_CALL ttcore_last_error(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->lastError() : "null player";
}

void TTCORE_CALL ttcore_set_volume(ttcore_player player, int volume) {
    if (auto* p = asPlayer(player)) {
        p->setVolume(volume);
    }
}

int TTCORE_CALL ttcore_get_volume(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->volume() : 0;
}

void TTCORE_CALL ttcore_set_muted(ttcore_player player, int muted) {
    if (auto* p = asPlayer(player)) {
        p->setMuted(muted != 0);
    }
}

int TTCORE_CALL ttcore_is_muted(ttcore_player player) {
    auto* p = asPlayer(player);
    return (p && p->isMuted()) ? 1 : 0;
}

void TTCORE_CALL ttcore_set_eq_enabled(ttcore_player player, int enabled) {
    if (auto* p = asPlayer(player)) {
        p->setEqEnabled(enabled != 0);
    }
}

int TTCORE_CALL ttcore_get_eq_enabled(ttcore_player player) {
    auto* p = asPlayer(player);
    return (p && p->eqEnabled()) ? 1 : 0;
}

void TTCORE_CALL ttcore_set_eq_gain(ttcore_player player, int band, double gain_db) {
    if (auto* p = asPlayer(player)) {
        p->setEqGain(band, gain_db);
    }
}

double TTCORE_CALL ttcore_get_eq_gain(ttcore_player player, int band) {
    auto* p = asPlayer(player);
    return p ? p->eqGain(band) : 0.0;
}

void TTCORE_CALL ttcore_set_preamp(ttcore_player player, double gain_db) {
    if (auto* p = asPlayer(player)) {
        p->setPreamp(gain_db);
    }
}

double TTCORE_CALL ttcore_get_preamp(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->preamp() : 0.0;
}

void TTCORE_CALL ttcore_set_balance(ttcore_player player, int balance) {
    if (auto* p = asPlayer(player)) {
        p->setBalance(balance);
    }
}

int TTCORE_CALL ttcore_get_balance(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->balance() : 0;
}

const char* TTCORE_CALL ttcore_get_title(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->title() : "";
}

const char* TTCORE_CALL ttcore_get_artist(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->artist() : "";
}

const char* TTCORE_CALL ttcore_get_album(ttcore_player player) {
    auto* p = asPlayer(player);
    return p ? p->album() : "";
}

int TTCORE_CALL ttcore_get_spectrum(ttcore_player player, float* out, int count) {
    auto* p = asPlayer(player);
    return p ? p->getSpectrum(out, count) : 0;
}

int TTCORE_CALL ttcore_get_cover(ttcore_player player, unsigned char* out, int cap) {
    auto* p = asPlayer(player);
    return p ? p->getCover(out, cap) : 0;
}

void TTCORE_CALL ttcore_set_progress_callback(ttcore_player player, ttcore_progress_cb cb, void* userdata) {
    if (auto* p = asPlayer(player)) {
        p->setProgressCallback(cb, userdata);
    }
}

void TTCORE_CALL ttcore_set_finished_callback(ttcore_player player, ttcore_finished_cb cb, void* userdata) {
    if (auto* p = asPlayer(player)) {
        p->setFinishedCallback(cb, userdata);
    }
}

void TTCORE_CALL ttcore_set_error_callback(ttcore_player player, ttcore_error_cb cb, void* userdata) {
    if (auto* p = asPlayer(player)) {
        p->setErrorCallback(cb, userdata);
    }
}

int TTCORE_CALL ttcore_read_metadata(const char* path_utf8, ttcore_metadata* out) {
    if (!out) {
        return 0;
    }
    std::memset(out, 0, sizeof(*out));
    if (!path_utf8 || !*path_utf8) {
        return 0;
    }

    AudioFileMetadata meta;
    if (!readAudioFileMetadata(path_utf8, meta)) {
        return 0;
    }
    copyUtf8Field(out->title, sizeof(out->title), meta.title);
    copyUtf8Field(out->artist, sizeof(out->artist), meta.artist);
    copyUtf8Field(out->album, sizeof(out->album), meta.album);
    out->duration_ms = meta.duration_ms;
    return 1;
}

int TTCORE_CALL ttcore_write_metadata(const char* path_utf8,
                                      const char* title_utf8,
                                      const char* artist_utf8,
                                      const char* album_utf8) {
    if (!path_utf8 || !*path_utf8) {
        return 0;
    }
    return writeAudioFileMetadata(path_utf8, title_utf8, artist_utf8, album_utf8) ? 1 : 0;
}

} // extern "C"
