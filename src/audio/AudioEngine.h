#pragma once
#include "Decoder.h"
#include "DspChain.h"
#include "AudioOutput.h"
#include <QObject>
#include <QString>
#include <QByteArray>
#include <QMutex>
#include <memory>
#include <atomic>

// 音频引擎类：封装解码、DSP、重采样和音频输出。
// 此类负责播放控制、进度、音量、静音、均衡器以及可视化数据。
class AudioEngine : public QObject {
    Q_OBJECT
public:
    enum State { Stopped, Playing, Paused };

    explicit AudioEngine(QObject* parent = nullptr);
    ~AudioEngine();

    // 加载音频文件，初始化解码器和输出设备。
    bool loadFile(const QString& filePath);
    // 开始播放已加载的音频。
    void play();
    // 暂停播放，保留当前进度。
    void pause();
    // 停止播放并重置状态。
    void stop();
    // 跳转到指定毫秒位置播放。
    void seek(int64_t positionMs);

    // 返回当前音频引擎状态。
    State state() const { return state_; }
    int64_t positionMs() const;
    int64_t durationMs() const;

    // 音量范围 [0, 100]
    void setVolume(int volume);
    int volume() const;

    // 设置静音状态。
    void setMuted(bool m);
    // 检查是否处于静音状态。
    bool isMuted() const;

    // 声道平衡范围 [-100,100]
    // 设置声道平衡，范围 [-100, 100]。
    void setBalance(int balance);

    DspChain& dspChain() { return dsp_; }

    // 获取当前音频电平，用于频谱仪或可视化。
    float currentLevel(int channel) const;

    // 获取频谱数据。
    void getSpectrumData(float* data, int size) const;

    // 获取当前曲目标题。
    QString currentTitle() const;
    // 获取当前曲目艺术家信息。
    QString currentArtist() const;
    // 获取当前曲目专辑信息。
    QString currentAlbum() const;
    // 获取当前曲目的封面图片二进制数据。
    QByteArray currentCoverArt() const;
    QString currentFilePath() const { return currentFile_; }

signals:
    void stateChanged(AudioEngine::State state);
    void positionChanged(int64_t positionMs);
    void durationChanged(int64_t durationMs);
    void volumeChanged(int volume);
    void mutedChanged(bool muted);
    void trackFinished();
    void errorOccurred(const QString& message);

private:
    void audioCallback(float* buffer, int frames);

    Decoder decoder_;
    DspChain dsp_;
    AudioOutput output_;

    QMutex mutex_;
    std::atomic<State> state_{Stopped};
    QString currentFile_;

    // 频谱分析缓存
    mutable QMutex spectrumMutex_;
    std::vector<float> spectrumBuf_;
    std::atomic<float> levelL_{0.0f};
    std::atomic<float> levelR_{0.0f};
};
