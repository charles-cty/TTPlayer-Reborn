#pragma once
#include "SkinData.h"
#include "SkinParser.h"
#include <QString>
#include <QMap>
#include <QImage>
#include <memory>

// 皮肤引擎，负责加载 TTPlayer 皮肤文件、解析皮肤资源并构建渲染数据。
class SkinEngine {
public:
    SkinEngine();

    // 从单个 .skn 文件加载皮肤。skn 文件本质上是 ZIP 压缩包。
    bool loadFromFile(const QString& sknPath);
    // 从皮肤目录加载皮肤，例如已经解压的 Skin 文件夹。
    bool loadFromDirectory(const QString& dirPath);

    // 加载内置默认皮肤，用于回退场景。
    bool loadDefault();

    const SkinData& skinData() const { return skin_; }
    bool isLoaded() const { return loaded_; }

    QString skinName() const { return skin_.name; }
    QString skinAuthor() const { return skin_.author; }

private:
    bool loadImages(const QString& dirPath, QMap<QString, QImage>& images);
    bool loadSkinConfigXml(const QString& xmlPath, SkinData& skin);

    SkinData skin_;
    SkinParser parser_;
    bool loaded_ = false;
};
