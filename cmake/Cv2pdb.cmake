# Windows MinGW: convert embedded DWARF to a sidecar PDB via cv2pdb.
# Debug / Profile / RelWithDebInfo only. No-op on other platforms and Release.

set(CV2PDB_EXECUTABLE "" CACHE FILEPATH "cv2pdb64.exe (DWARF to PDB)")

function(_ttplayer_need_cv2pdb out_var)
    set(_need FALSE)
    if (WIN32)
        if (CMAKE_CONFIGURATION_TYPES)
            set(_need TRUE)
        elseif (CMAKE_BUILD_TYPE MATCHES "^(Debug|Profile|RelWithDebInfo)$")
            set(_need TRUE)
        endif()
    endif()
    set(${out_var} "${_need}" PARENT_SCOPE)
endfunction()

_ttplayer_need_cv2pdb(_TTPLAYER_NEED_CV2PDB)

if (_TTPLAYER_NEED_CV2PDB AND NOT CV2PDB_EXECUTABLE)
    find_program(CV2PDB_EXECUTABLE
        NAMES cv2pdb64.exe cv2pdb64 cv2pdb.exe cv2pdb
        PATHS
            "${CMAKE_SOURCE_DIR}/tools/.cache/cv2pdb"
            ENV CV2PDB_HOME
        DOC "cv2pdb (DWARF to PDB)"
    )
endif()

if (_TTPLAYER_NEED_CV2PDB AND NOT CV2PDB_EXECUTABLE)
    message(FATAL_ERROR
        "cv2pdb not found (needed for ${CMAKE_BUILD_TYPE} PDB on Windows).\n"
        "Run: pwsh -File tools/build-ttcore-win.ps1 -Config ${CMAKE_BUILD_TYPE}\n"
        "or set -DCV2PDB_EXECUTABLE=... to cv2pdb64.exe.")
endif()

if (CV2PDB_EXECUTABLE)
    message(STATUS "cv2pdb: ${CV2PDB_EXECUTABLE}")
endif()

function(ttplayer_convert_dwarf_to_pdb tgt)
    if (NOT WIN32 OR NOT CV2PDB_EXECUTABLE)
        return()
    endif()
    if (NOT TARGET ${tgt})
        message(FATAL_ERROR "ttplayer_convert_dwarf_to_pdb: unknown target ${tgt}")
    endif()
    add_custom_command(TARGET ${tgt} POST_BUILD
        COMMAND ${CMAKE_COMMAND}
            "-DCV2PDB=${CV2PDB_EXECUTABLE}"
            "-DBIN=$<TARGET_FILE:${tgt}>"
            "-DCFG=$<CONFIG>"
            -P "${CMAKE_SOURCE_DIR}/cmake/RunCv2pdb.cmake"
        COMMENT "cv2pdb $<TARGET_FILE_NAME:${tgt}> ($<CONFIG>)"
        VERBATIM
    )
endfunction()
