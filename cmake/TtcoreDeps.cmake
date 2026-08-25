# FFmpeg + SDL2 for ttcore and the Qt app.
# Linux: pkg-config shared libs.
# Windows: bundled static audio-only FFmpeg (tools/build-ffmpeg-win.ps1) + SDL2.dll.

option(TTCORE_STATIC_FFMPEG "Link a bundled static audio-only FFmpeg" OFF)
set(TTCORE_FFMPEG_ROOT "${CMAKE_SOURCE_DIR}/build-ffmpeg-mingw64/prefix"
    CACHE PATH "Prefix produced by tools/build-ffmpeg-win.ps1")

if (WIN32)
    set(TTCORE_STATIC_FFMPEG ON CACHE BOOL "Link a bundled static audio-only FFmpeg" FORCE)
endif()

find_package(PkgConfig REQUIRED)

if (TTCORE_STATIC_FFMPEG)
    if (NOT EXISTS "${TTCORE_FFMPEG_ROOT}/lib/libavcodec.a")
        message(FATAL_ERROR
            "TTCORE_STATIC_FFMPEG is ON but ${TTCORE_FFMPEG_ROOT}/lib/libavcodec.a is missing.\n"
            "On Windows run: pwsh -File tools/build-ffmpeg-win.ps1")
    endif()
    # Do not use pkg-config: FFmpeg's .pc prefix is an MSYS path, and putting
    # mingw64/lib/pkgconfig on PKG_CONFIG_PATH would pull the shared kitchen sink.
    set(_ff_inc "${TTCORE_FFMPEG_ROOT}/include")
    set(_ff_lib "${TTCORE_FFMPEG_ROOT}/lib")
    set(AVFORMAT_INCLUDE_DIRS "${_ff_inc}")
    set(AVCODEC_INCLUDE_DIRS "${_ff_inc}")
    set(AVUTIL_INCLUDE_DIRS "${_ff_inc}")
    set(SWRESAMPLE_INCLUDE_DIRS "${_ff_inc}")
    set(AVFORMAT_LIBRARY_DIRS "${_ff_lib}")
    set(AVCODEC_LIBRARY_DIRS "${_ff_lib}")
    set(AVUTIL_LIBRARY_DIRS "${_ff_lib}")
    set(SWRESAMPLE_LIBRARY_DIRS "${_ff_lib}")
    set(AVFORMAT_CFLAGS_OTHER "")
    set(AVCODEC_CFLAGS_OTHER "")
    set(AVUTIL_CFLAGS_OTHER "")
    set(SWRESAMPLE_CFLAGS_OTHER "")
    # Prefer the .a files: -lz/-liconv would pick mingw *.dll.a import libs.
    get_filename_component(_mingw_bin "${CMAKE_CXX_COMPILER}" DIRECTORY)
    get_filename_component(_mingw_root "${_mingw_bin}" DIRECTORY)
    set(_mingw_lib "${_mingw_root}/lib")
    set(_ttcore_sys_static "")
    foreach (_n IN ITEMS libz.a libiconv.a)
        if (EXISTS "${_mingw_lib}/${_n}")
            list(APPEND _ttcore_sys_static "${_mingw_lib}/${_n}")
        endif()
    endforeach()
    if (EXISTS "${_mingw_lib}/libwinpthread.a")
        set(TTCORE_WINPTHREAD_STATIC "${_mingw_lib}/libwinpthread.a")
    endif()
    set(AVFORMAT_LIBRARIES
        "${_ff_lib}/libavformat.a"
        "${_ff_lib}/libavcodec.a"
        "${_ff_lib}/libswresample.a"
        "${_ff_lib}/libavutil.a"
        ${_ttcore_sys_static}
        bcrypt ole32 user32 atomic)
    set(AVCODEC_LIBRARIES "")
    set(AVUTIL_LIBRARIES "")
    set(SWRESAMPLE_LIBRARIES "")
    message(STATUS "Static FFmpeg: ${TTCORE_FFMPEG_ROOT}")
else()
    pkg_check_modules(AVFORMAT REQUIRED libavformat)
    pkg_check_modules(AVCODEC REQUIRED libavcodec)
    pkg_check_modules(AVUTIL REQUIRED libavutil)
    pkg_check_modules(SWRESAMPLE REQUIRED libswresample)
endif()

set(SDL2_DLL "")
if (WIN32)
    # Build-time only: SDL2_PREFIX or pkg-config. The shipped layout is
    # SDL2.dll copied next to ttcore.dll — no hardcoded C:\Programs path.
    set(_sdl2_found FALSE)
    if (DEFINED ENV{SDL2_PREFIX} AND NOT "$ENV{SDL2_PREFIX}" STREQUAL "")
        set(_root "$ENV{SDL2_PREFIX}")
        if (EXISTS "${_root}/include/SDL2/SDL.h" AND EXISTS "${_root}/bin/SDL2.dll")
            set(SDL2_INCLUDE_DIRS "${_root}/include" "${_root}/include/SDL2")
            set(SDL2_LIBRARY_DIRS "${_root}/lib")
            # DLL host: do not pull SDL2main / -mwindows from sdl2.pc.
            set(SDL2_LIBRARIES SDL2)
            set(SDL2_CFLAGS_OTHER "")
            set(SDL2_DLL "${_root}/bin/SDL2.dll")
            set(_sdl2_found TRUE)
            message(STATUS "SDL2: ${_root} (SDL2_PREFIX)")
        endif()
    endif()
    if (NOT _sdl2_found)
        pkg_check_modules(SDL2 REQUIRED sdl2)
        set(_sdl2_dll_candidates "")
        if (SDL2_PREFIX)
            list(APPEND _sdl2_dll_candidates "${SDL2_PREFIX}/bin/SDL2.dll")
        endif()
        if (SDL2_LIBDIR)
            get_filename_component(_sdl2_pc_root "${SDL2_LIBDIR}" DIRECTORY)
            list(APPEND _sdl2_dll_candidates "${_sdl2_pc_root}/bin/SDL2.dll")
        endif()
        foreach (_d IN LISTS SDL2_LIBRARY_DIRS)
            get_filename_component(_sdl2_lib_root "${_d}" DIRECTORY)
            list(APPEND _sdl2_dll_candidates "${_sdl2_lib_root}/bin/SDL2.dll" "${_d}/SDL2.dll")
        endforeach()
        get_filename_component(_mingw_bin "${CMAKE_CXX_COMPILER}" DIRECTORY)
        list(APPEND _sdl2_dll_candidates "${_mingw_bin}/SDL2.dll")
        foreach (_c IN LISTS _sdl2_dll_candidates)
            if (EXISTS "${_c}")
                set(SDL2_DLL "${_c}")
                break()
            endif()
        endforeach()
        if (SDL2_DLL)
            message(STATUS "SDL2.dll: ${SDL2_DLL}")
        endif()
    endif()
    if (NOT SDL2_DLL)
        message(FATAL_ERROR
            "SDL2.dll not found. Set SDL2_PREFIX to a MinGW SDL2 root "
            "(include/SDL2/SDL.h and bin/SDL2.dll) or put sdl2 on PKG_CONFIG_PATH.")
    endif()
else()
    pkg_check_modules(SDL2 REQUIRED sdl2)
endif()
