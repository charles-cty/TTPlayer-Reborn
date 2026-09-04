# Debug / Release / Profile.
# Profile = Release optimization + debug info + frame pointers (sampling profilers).
# RelWithDebInfo remains available for CMake compatibility; scripts use Profile.

if (NOT CMAKE_CONFIGURATION_TYPES)
    if (NOT CMAKE_BUILD_TYPE)
        set(CMAKE_BUILD_TYPE "Debug" CACHE STRING
            "Build type: Debug, Release, or Profile" FORCE)
    endif()
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
        Debug Release Profile RelWithDebInfo MinSizeRel)
else()
    list(APPEND CMAKE_CONFIGURATION_TYPES Profile)
    list(REMOVE_DUPLICATES CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_CONFIGURATION_TYPES "${CMAKE_CONFIGURATION_TYPES}" CACHE STRING
        "Multi-config types" FORCE)
endif()

# project() with CMAKE_BUILD_TYPE=Profile can cache an empty
# CMAKE_*_FLAGS_PROFILE from a missing INIT. Fill from Release if so.
foreach (_lang IN ITEMS C CXX)
    if (NOT CMAKE_${_lang}_FLAGS_PROFILE MATCHES "(-O[123s]|[/-]O2)")
        set(CMAKE_${_lang}_FLAGS_PROFILE "${CMAKE_${_lang}_FLAGS_RELEASE}"
            CACHE STRING "${_lang} flags for Profile" FORCE)
    endif()
    mark_as_advanced(CMAKE_${_lang}_FLAGS_PROFILE)
endforeach()
foreach (_kind IN ITEMS EXE SHARED MODULE STATIC)
    if (NOT DEFINED CMAKE_${_kind}_LINKER_FLAGS_PROFILE)
        set(CMAKE_${_kind}_LINKER_FLAGS_PROFILE "${CMAKE_${_kind}_LINKER_FLAGS_RELEASE}"
            CACHE STRING "${_kind} linker flags for Profile")
    endif()
    mark_as_advanced(CMAKE_${_kind}_LINKER_FLAGS_PROFILE)
endforeach()

if (CMAKE_C_COMPILER_ID MATCHES "GNU|Clang" OR CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    # -g on Profile: Release flags have no debug info.
    # -fno-omit-frame-pointer: usable stacks in perf / ETW / WPA.
    # -gdwarf-4 on Windows: cv2pdb is more reliable than DWARF-5.
    add_compile_options(
        $<$<CONFIG:Profile>:-g>
        $<$<CONFIG:Profile>:-fno-omit-frame-pointer>
    )
    add_link_options(
        $<$<CONFIG:Profile>:-fno-omit-frame-pointer>
    )
    if (WIN32)
        add_compile_options(
            $<$<CONFIG:Debug>:-gdwarf-4>
            $<$<CONFIG:Profile>:-gdwarf-4>
            $<$<CONFIG:RelWithDebInfo>:-gdwarf-4>
        )
    endif()
endif()
