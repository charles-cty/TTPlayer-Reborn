#include "AudioEngine.h"
#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <QElapsedTimer>
#include <cstring>
#include <cmath>
#include <algorithm>

AudioEngine::AudioEngine(QObject* parent)
    : QObject(parent)
{
    spectrumBuf_.resize(1024, 0.0f);
}

AudioEngine::~AudioEngine() {
    stop();
}

// 加载指定音频文件，初始化解码器和输出设备。
bool AudioEngine::loadFile(const QString& filePath) {
    QElapsedTimer totalTimer;
    totalTimer.start();

    QElapsedTimer phaseTimer;
    phaseTimer.start();
    output_.pause();
    const qint64 pauseOutputMs = phaseTimer.elapsed();

    phaseTimer.restart();
    QMutexLocker lock(&mutex_);
    decoder_.close();
    state_ = Stopped;
    currentFile_.clear();
    const qint64 decoderResetMs = phaseTimer.elapsed();

    const QByteArray encodedPath = QFile::encodeName(filePath);
    std::string path(encodedPath.constData(), static_cast<size_t>(encodedPath.size()));
    phaseTimer.restart();
    if (!decoder_.open(path)) {
        const qint64 openDecoderMs = phaseTimer.elapsed();
        const QString reason = QString::fromStdString(decoder_.lastError());
        lock.unlock();
        qDebug().noquote()
            << QStringLiteral("[SwitchPerf][AudioEngine] loadFile failed path=\"%1\" total=%2ms pause_output=%3ms decoder_reset=%4ms decoder_open=%5ms reason=\"%6\"")
                   .arg(filePath)
                   .arg(totalTimer.elapsed())
                   .arg(pauseOutputMs)
                   .arg(decoderResetMs)
                   .arg(openDecoderMs)
                   .arg(reason);
        emit positionChanged(0);
        emit errorOccurred(reason.isEmpty()
            ? tr("Failed to open: %1").arg(filePath)
            : tr("Failed to open: %1\n%2").arg(filePath, reason));
        return false;
    }
    const qint64 openDecoderMs = phaseTimer.elapsed();

    currentFile_ = filePath;
    phaseTimer.restart();
    auto fmt = decoder_.format();
    dsp_.setSampleRate(fmt.sampleRate);
    dsp_.equalizer.setSampleRate(fmt.sampleRate);
    const qint64 setupMs = phaseTimer.elapsed();

    // 设置音频输出回调
    auto cb = [this](float* buf, int frames) { audioCallback(buf, frames); };
    const bool reusedOutput = output_.isCompatible(fmt.sampleRate, fmt.channels);
    phaseTimer.restart();
    if (!output_.open(fmt.sampleRate, fmt.channels, cb)) {
        const qint64 openOutputMs = phaseTimer.elapsed();
        lock.unlock();
        qDebug().noquote()
            << QStringLiteral("[SwitchPerf][AudioEngine] loadFile failed path=\"%1\" total=%2ms pause_output=%3ms decoder_reset=%4ms decoder_open=%5ms setup=%6ms output_open=%7ms output_reused=%8 reason=\"audio_output_open_failed\"")
                   .arg(filePath)
                   .arg(totalTimer.elapsed())
                   .arg(pauseOutputMs)
                   .arg(decoderResetMs)
                   .arg(openDecoderMs)
                   .arg(setupMs)
                   .arg(openOutputMs)
                   .arg(reusedOutput ? 1 : 0);
        emit errorOccurred(tr("Failed to open audio output"));
        decoder_.close();
        emit positionChanged(0);
        return false;
    }
    const qint64 openOutputMs = phaseTimer.elapsed();
    lock.unlock();

    emit positionChanged(0);
    phaseTimer.restart();
    emit durationChanged(decoder_.durationMs());
    const qint64 emitDurationMs = phaseTimer.elapsed();

    qDebug().noquote()
        << QStringLiteral("[SwitchPerf][AudioEngine] loadFile ok path=\"%1\" total=%2ms pause_output=%3ms decoder_reset=%4ms decoder_open=%5ms setup=%6ms output_open=%7ms output_reused=%8 emit_duration=%9ms sr=%10 ch=%11")
               .arg(filePath)
               .arg(totalTimer.elapsed())
               .arg(pauseOutputMs)
               .arg(decoderResetMs)
               .arg(openDecoderMs)
               .arg(setupMs)
               .arg(openOutputMs)
               .arg(reusedOutput ? 1 : 0)
               .arg(emitDurationMs)
               .arg(fmt.sampleRate)
               .arg(fmt.channels);
    return true;
}

// 开始播放当前已加载的音频文件。
void AudioEngine::play() {
    QElapsedTimer timer;
    timer.start();
    QMutexLocker lock(&mutex_);
    if (!decoder_.isOpen()) return;
    output_.start();
    state_ = Playing;
    emit stateChanged(state_);
    qDebug().noquote()
        << QStringLiteral("[SwitchPerf][AudioEngine] play start file=\"%1\" elapsed=%2ms")
               .arg(currentFile_)
               .arg(timer.elapsed());
}

// 暂停播放，但保留当前位置。
void AudioEngine::pause() {
    QElapsedTimer totalTimer;
    totalTimer.start();
    QMutexLocker lock(&mutex_);

    const QString pausedFile = currentFile_;
    const auto previousState = state_.load();

    QElapsedTimer phaseTimer;
    phaseTimer.start();
    const qint64 currentPosMs = decoder_.isOpen() ? decoder_.positionMs() : 0;
    const qint64 queryPositionMs = phaseTimer.elapsed();

    phaseTimer.restart();
    output_.pause();
    const qint64 outputMs = phaseTimer.elapsed();

    state_ = Paused;

    phaseTimer.restart();
    emit stateChanged(state_);
    const qint64 emitStateMs = phaseTimer.elapsed();
    lock.unlock();

    qDebug().noquote()
        << QStringLiteral("[SwitchPerf][AudioEngine] pause total=%1ms query_position=%2ms output=%3ms emit_state=%4ms position=%5ms from_state=%6 to_state=%7 file=\"%8\"")
               .arg(totalTimer.elapsed())
               .arg(queryPositionMs)
               .arg(outputMs)
               .arg(emitStateMs)
               .arg(currentPosMs)
               .arg(static_cast<int>(previousState))
               .arg(static_cast<int>(Paused))
               .arg(pausedFile);
}

// 停止播放并关闭输出设备，同时重置解码器状态。
void AudioEngine::stop() {
    QElapsedTimer timer;
    timer.start();
    const QString previousFile = currentFile_;
    const auto previousState = state_.load();

    output_.pause();
    output_.close();
    const qint64 outputMs = timer.elapsed();
    {
        QMutexLocker lock(&mutex_);
        decoder_.close();
    }
    const qint64 decoderMs = timer.elapsed() - outputMs;
    state_ = Stopped;
    currentFile_.clear();
    emit stateChanged(state_);
    emit positionChanged(0);

    const qint64 totalMs = timer.elapsed();
    if (totalMs >= 5 || previousState != Stopped) {
        qDebug().noquote()
            << QStringLiteral("[SwitchPerf][AudioEngine] stop total=%1ms output=%2ms decoder=%3ms from_state=%4 from_file=\"%5\"")
                   .arg(totalMs)
                   .arg(outputMs)
                   .arg(decoderMs)
                   .arg(static_cast<int>(previousState))
                   .arg(previousFile);
    }
}

// 跳转到指定播放位置（毫秒）。
void AudioEngine::seek(int64_t positionMs) {
    QMutexLocker lock(&mutex_);
    if (decoder_.isOpen()) {
        decoder_.seek(positionMs);
        emit positionChanged(positionMs);
    }
}

// 获取当前播放位置（毫秒）。
int64_t AudioEngine::positionMs() const {
    return decoder_.positionMs();
}

// 获取当前音频文件总时长（毫秒）。
int64_t AudioEngine::durationMs() const {
    return decoder_.durationMs();
}

// 设置播放音量，输入范围 [0, 100]。
void AudioEngine::setVolume(int volume) {
    const int clamped = std::clamp(volume, 0, 100);
    dsp_.setVolume(clamped / 100.0f);
    emit volumeChanged(clamped);
}

int AudioEngine::volume() const {
    return static_cast<int>(dsp_.volume() * 100);
}

// 设置静音状态。
void AudioEngine::setMuted(bool m) {
    dsp_.setMuted(m);
    emit mutedChanged(m);
}

bool AudioEngine::isMuted() const {
    return dsp_.isMuted();
}

// 设置声道平衡，左声道负值、右声道正值。
void AudioEngine::setBalance(int balance) {
    dsp_.setBalance(std::clamp(balance, -100, 100) / 100.0f);
}

float AudioEngine::currentLevel(int channel) const {
    return channel == 0 ? levelL_.load() : levelR_.load();
}

void AudioEngine::getSpectrumData(float* data, int size) const {
    QMutexLocker lock(&spectrumMutex_);
    int n = std::min(size, static_cast<int>(spectrumBuf_.size()));
    std::memcpy(data, spectrumBuf_.data(), n * sizeof(float));
}

QString AudioEngine::currentTitle() const {
    auto t = decoder_.title();
    return t.empty() ? QFileInfo(currentFile_).completeBaseName() : QString::fromStdString(t);
}

QString AudioEngine::currentArtist() const {
    return QString::fromStdString(decoder_.artist());
}

QString AudioEngine::currentAlbum() const {
    return QString::fromStdString(decoder_.album());
}

QByteArray AudioEngine::currentCoverArt() const {
    const auto& cover = decoder_.coverArtData();
    if (cover.empty()) {
        return {};
    }
    return QByteArray(reinterpret_cast<const char*>(cover.data()),
                      static_cast<qsizetype>(cover.size()));
}

// 音频回调函数，由输出设备定期调用，将音频数据填充到输出缓冲区。
// 音频输出回调，被 AudioOutput 定期调用来填充播放缓冲区。
void AudioEngine::audioCallback(float* buffer, int frames) {
    QMutexLocker lock(&mutex_);
    if (state_ != Playing || !decoder_.isOpen()) {
        std::memset(buffer, 0, frames * output_.channels() * sizeof(float));
        return;
    }

    AudioBuffer abuf;
    int read = decoder_.read(abuf, frames);
    if (read <= 0) {
        std::memset(buffer, 0, frames * output_.channels() * sizeof(float));
        if (read == 0) {
            // 到达文件末尾——曲目播放结束
            QMetaObject::invokeMethod(this, [this]() {
                emit trackFinished();
            }, Qt::QueuedConnection);
        }
        return;
    }

    // 应用 DSP 处理
    dsp_.process(abuf.data.data(), read, abuf.channels);

    // 复制音频数据到输出缓冲区
    int samplesToWrite = read * output_.channels();
    int outputSamples = frames * output_.channels();
    int toCopy = std::min(samplesToWrite, outputSamples);
    std::memcpy(buffer, abuf.data.data(), toCopy * sizeof(float));

    // 对剩余区域进行零填充
    if (toCopy < outputSamples) {
        std::memset(buffer + toCopy, 0, (outputSamples - toCopy) * sizeof(float));
    }

    // 更新可视化音量电平
    float maxL = 0, maxR = 0;
    int ch = output_.channels();
    for (int i = 0; i < read; ++i) {
        float l = std::abs(buffer[i * ch]);
        if (ch > 1) {
            float r = std::abs(buffer[i * ch + 1]);
            maxR = std::max(maxR, r);
        }
        maxL = std::max(maxL, l);
    }
    levelL_ = maxL;
    levelR_ = maxR;

    // 存储频谱数据
    {
        QMutexLocker slock(&spectrumMutex_);
        int n = std::min(read, static_cast<int>(spectrumBuf_.size()));
        for (int i = 0; i < n; ++i) {
            spectrumBuf_[i] = buffer[i * ch]; // 左声道数据
        }
    }

    // 发送播放位置更新信号
    QMetaObject::invokeMethod(this, [this]() {
        emit positionChanged(decoder_.positionMs());
    }, Qt::QueuedConnection);
}
