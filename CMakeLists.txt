cmake_minimum_required(VERSION 3.20)
project(TTPlayerReborn VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Qt6
find_package(Qt6 REQUIRED COMPONENTS Widgets Multimedia Network)
# DBus 在 Linux 上默认可用，macOS/Windows 则可能没有，设为可选。
find_package(Qt6 OPTIONAL_COMPONENTS DBus)

# FFmpeg
find_package(PkgConfig REQUIRED)
pkg_check_modules(AVFORMAT REQUIRED libavformat)
pkg_check_modules(AVCODEC REQUIRED libavcodec)
pkg_check_modules(AVUTIL REQUIRED libavutil)
pkg_check_modules(SWRESAMPLE REQUIRED libswresample)

# SDL2
pkg_check_modules(SDL2 REQUIRED sdl2)

# TagLib
pkg_check_modules(TAGLIB REQUIRED taglib)

# libsoxr
pkg_check_modules(SOXR REQUIRED soxr)

# QuaZip
find_package(QuaZip-Qt6 REQUIRED)

if (UNIX AND NOT APPLE)
    find_package(X11 QUIET)
endif()

set(SOURCES
    src/main.cpp
    src/app/Application.cpp
    src/app/Config.cpp
    src/audio/AudioEngine.cpp
    src/audio/Decoder.cpp
    src/audio/DspChain.cpp
    src/audio/Equalizer.cpp
    src/audio/AudioOutput.cpp
    src/skin/SkinEngine.cpp
    src/skin/SkinParser.cpp
    src/skin/SkinButton.cpp
    src/tools/SkinDumper.cpp
    src/tools/FrameDumper.cpp
    src/ui/PlayerWindow.cpp
    src/ui/LyricWindow.cpp
    src/ui/EqualizerWindow.cpp
    src/ui/PlaylistWindow.cpp
    src/ui/WindowSnapManager.cpp
    src/ui/VisualWidget.cpp
    src/lyric/LrcParser.cpp
    src/playlist/PlaylistManager.cpp
    src/playlist/TtblParser.cpp
    src/playlist/TtblWriter.cpp
    src/playlist/PlaylistMetadataLoader.cpp
)

set(HEADERS
    src/app/Application.h
    src/app/Config.h
    src/audio/AudioEngine.h
    src/audio/Decoder.h
    src/audio/DspChain.h
    src/audio/Equalizer.h
    src/audio/AudioOutput.h
    src/skin/SkinEngine.h
    src/skin/SkinParser.h
    src/skin/SkinButton.h
    src/tools/SkinDumper.h
    src/tools/FrameDumper.h
    src/ui/PlayerWindow.h
    src/ui/LyricWindow.h
    src/ui/EqualizerWindow.h
    src/ui/PlaylistWindow.h
    src/ui/WindowSnapManager.h
    src/ui/VisualWidget.h
    src/lyric/LrcParser.h
    src/playlist/PlaylistManager.h
    src/playlist/TtblParser.h
    src/playlist/TtblWriter.h
    src/playlist/PlaylistMetadataLoader.h
)

add_executable(${PROJECT_NAME} ${SOURCES} ${HEADERS})

target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${AVFORMAT_INCLUDE_DIRS}
    ${AVCODEC_INCLUDE_DIRS}
    ${AVUTIL_INCLUDE_DIRS}
    ${SWRESAMPLE_INCLUDE_DIRS}
    ${SDL2_INCLUDE_DIRS}
    ${TAGLIB_INCLUDE_DIRS}
    ${SOXR_INCLUDE_DIRS}
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    Qt6::Widgets
    Qt6::Multimedia
    Qt6::Network
    ${AVFORMAT_LIBRARIES}
    ${AVCODEC_LIBRARIES}
    ${AVUTIL_LIBRARIES}
    ${SWRESAMPLE_LIBRARIES}
    ${SDL2_LIBRARIES}
    ${TAGLIB_LIBRARIES}
    ${SOXR_LIBRARIES}
    QuaZip::QuaZip
)
if (X11_FOUND)
    target_link_libraries(${PROJECT_NAME} PRIVATE X11::X11)
    target_compile_definitions(${PROJECT_NAME} PRIVATE TTPLAYER_HAS_X11_HOTKEYS)
endif()
# DBus 可选：Linux 普通可用，macOS/Windows 不强制要求
if (Qt6DBus_FOUND)
    target_link_libraries(${PROJECT_NAME} PRIVATE Qt6::DBus)
    target_compile_definitions(${PROJECT_NAME} PRIVATE QT_DBUS_LIB)
endif()
# Windows: 任判1 thumbnail 工具栏库 + WinRT 运行时库
if (WIN32)
    target_link_libraries(${PROJECT_NAME} PRIVATE comctl32)
    # runtimeobject 用于 WinRT/SMTC（MSVC + SDK 8.1+）
    if (MSVC)
        target_link_libraries(${PROJECT_NAME} PRIVATE runtimeobject)
    endif()
endif()

target_link_directories(${PROJECT_NAME} PRIVATE
    ${AVFORMAT_LIBRARY_DIRS}
    ${AVCODEC_LIBRARY_DIRS}
    ${AVUTIL_LIBRARY_DIRS}
    ${SWRESAMPLE_LIBRARY_DIRS}
    ${SDL2_LIBRARY_DIRS}
    ${TAGLIB_LIBRARY_DIRS}
    ${SOXR_LIBRARY_DIRS}
)
