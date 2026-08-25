cmake_minimum_required(VERSION 3.20)
project(TTPlayerReborn VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(BUILD_QT_APP "Build the Qt TTPlayerReborn GUI executable" ON)

if (BUILD_QT_APP)
    set(CMAKE_AUTOMOC ON)
    set(CMAKE_AUTORCC ON)
endif()

include("${CMAKE_SOURCE_DIR}/cmake/TtcoreDeps.cmake")

# ---------------------------------------------------------------------------
# ttcore: Qt-free C ABI around Decoder / DspChain / Equalizer / AudioOutput.
# ---------------------------------------------------------------------------
add_library(ttcore SHARED
    src/audio/Decoder.cpp
    src/audio/DspChain.cpp
    src/audio/Equalizer.cpp
    src/audio/AudioOutput.cpp
    src/audio/Metadata.cpp
    src/ttcore/ttcore.cpp
)
target_include_directories(ttcore
    PUBLIC
        ${CMAKE_SOURCE_DIR}/src/ttcore
    PRIVATE
        ${CMAKE_SOURCE_DIR}/src
        ${CMAKE_SOURCE_DIR}/src/audio
        ${AVFORMAT_INCLUDE_DIRS}
        ${AVCODEC_INCLUDE_DIRS}
        ${AVUTIL_INCLUDE_DIRS}
        ${SWRESAMPLE_INCLUDE_DIRS}
        ${SDL2_INCLUDE_DIRS}
)
target_compile_definitions(ttcore PRIVATE TTCORE_EXPORTS _USE_MATH_DEFINES)
target_compile_options(ttcore PRIVATE
    ${AVFORMAT_CFLAGS_OTHER}
    ${AVCODEC_CFLAGS_OTHER}
    ${AVUTIL_CFLAGS_OTHER}
    ${SWRESAMPLE_CFLAGS_OTHER}
    ${SDL2_CFLAGS_OTHER}
)
target_link_directories(ttcore PRIVATE
    ${AVFORMAT_LIBRARY_DIRS}
    ${AVCODEC_LIBRARY_DIRS}
    ${AVUTIL_LIBRARY_DIRS}
    ${SWRESAMPLE_LIBRARY_DIRS}
    ${SDL2_LIBRARY_DIRS}
)
target_link_libraries(ttcore PRIVATE
    ${AVFORMAT_LIBRARIES}
    ${AVCODEC_LIBRARIES}
    ${SWRESAMPLE_LIBRARIES}
    ${AVUTIL_LIBRARIES}
    ${SDL2_LIBRARIES}
)
set(_ttcore_rpath "$ORIGIN")
foreach(_d IN LISTS AVFORMAT_LIBRARY_DIRS AVCODEC_LIBRARY_DIRS AVUTIL_LIBRARY_DIRS SWRESAMPLE_LIBRARY_DIRS SDL2_LIBRARY_DIRS)
    if (_d)
        list(APPEND _ttcore_rpath "${_d}")
    endif()
endforeach()
set_target_properties(ttcore PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    POSITION_INDEPENDENT_CODE ON
    OUTPUT_NAME ttcore
    BUILD_RPATH "${_ttcore_rpath}"
    INSTALL_RPATH "${_ttcore_rpath}"
)
# MinGW would otherwise emit libttcore.dll; Pascal LoadLibrary looks for ttcore.dll.
if (WIN32)
    set_target_properties(ttcore PROPERTIES PREFIX "")
endif()
# Windows ship layout: FFmpeg + libgcc/libstdc++/winpthread inside ttcore.dll.
# SDL2 stays a separate official DLL. --exclude-libs keeps av_* from leaking.
if (WIN32 AND MINGW)
    target_link_options(ttcore PRIVATE
        -static-libgcc
        -static-libstdc++
        -Wl,--exclude-libs,ALL
    )
    # Full-path .a at the end so libstdc++'s pthread refs do not pull the DLL.
    if (TTCORE_WINPTHREAD_STATIC)
        target_link_libraries(ttcore PRIVATE "${TTCORE_WINPTHREAD_STATIC}")
    endif()
endif()

add_executable(ttcore_probe src/ttcore/ttcore_probe.c)
target_link_libraries(ttcore_probe PRIVATE ttcore)
target_include_directories(ttcore_probe PRIVATE ${CMAKE_SOURCE_DIR}/src/ttcore)
# Probe only links ttcore; FFmpeg's optional DT_NEEDED (gme/openmpt/...) must not
# fail the executable link when those runtime .so files are resolved via RPATH.
if (NOT WIN32)
    target_link_options(ttcore_probe PRIVATE "-Wl,--allow-shlib-undefined")
endif()
set_target_properties(ttcore_probe PROPERTIES
    LINKER_LANGUAGE CXX
    BUILD_RPATH "$ORIGIN;${_ttcore_rpath}"
    INSTALL_RPATH "$ORIGIN;${_ttcore_rpath}"
)

set(_pascal_bin "${CMAKE_SOURCE_DIR}/pascal/bin")
add_custom_command(TARGET ttcore POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_pascal_bin}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:ttcore> "${_pascal_bin}/"
    COMMENT "Copy ttcore shared library to pascal/bin"
)
if (WIN32 AND SDL2_DLL)
    add_custom_command(TARGET ttcore POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${SDL2_DLL}" "$<TARGET_FILE_DIR:ttcore>/"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${SDL2_DLL}" "${_pascal_bin}/"
        COMMENT "Copy SDL2.dll next to ttcore.dll"
    )
endif()
add_custom_command(TARGET ttcore_probe POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:ttcore_probe> "${_pascal_bin}/"
    COMMENT "Copy ttcore_probe to pascal/bin"
)

if (NOT BUILD_QT_APP)
    return()
endif()

# Qt6
find_package(Qt6 REQUIRED COMPONENTS Widgets)
# DBus 在 Linux 上默认可用，macOS/Windows 则可能没有，设为可选。
find_package(Qt6 OPTIONAL_COMPONENTS DBus)

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
    src/audio/Metadata.cpp
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
    src/audio/Metadata.h
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
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    Qt6::Widgets
    ${AVFORMAT_LIBRARIES}
    ${AVCODEC_LIBRARIES}
    ${AVUTIL_LIBRARIES}
    ${SWRESAMPLE_LIBRARIES}
    ${SDL2_LIBRARIES}
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
)
