add_library(tttracy SHARED tracyshim.cpp ${CMAKE_SOURCE_DIR}/third_party/tracy/public/TracyClient.cpp)
target_compile_definitions(tttracy PRIVATE TTPLAYER_TRACY TRACY_ENABLE)
target_include_directories(tttracy PRIVATE ${CMAKE_SOURCE_DIR}/third_party/tracy/public)
set_target_properties(tttracy PROPERTIES PREFIX "")
if (MSVC)
    set_property(TARGET tttracy PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

add_executable(tttracy_test EXCLUDE_FROM_ALL tracyshim.cpp tests/tracyshim_test.cpp)
target_compile_definitions(tttracy_test PRIVATE TRACY_ENABLE)
target_include_directories(tttracy_test PRIVATE ${CMAKE_SOURCE_DIR}/third_party/tracy/public)

set(_tracy_deploy_dir "${CMAKE_SOURCE_DIR}/pascal/bin")
add_custom_command(TARGET tttracy POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_tracy_deploy_dir}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:tttracy>" "${_tracy_deploy_dir}/"
    COMMENT "Copy tttracy DLL to pascal/bin"
    VERBATIM
)

if (MSVC)
    set(_tracy_pdb_dir "$<TARGET_PDB_FILE_DIR:tttracy>")
    set(_tracy_pdb_base "$<TARGET_PDB_FILE_BASE_NAME:tttracy>")
else()
    set(_tracy_pdb_dir "$<TARGET_FILE_DIR:tttracy>")
    set(_tracy_pdb_base "$<TARGET_FILE_BASE_NAME:tttracy>")
endif()
add_custom_command(TARGET tttracy POST_BUILD
    COMMAND ${CMAKE_COMMAND}
        "-Dsrc=${_tracy_pdb_dir}"
        "-Dbase=${_tracy_pdb_base}"
        "-Ddst=${_tracy_deploy_dir}"
        -P "${CMAKE_SOURCE_DIR}/cmake/CopyPdbIfPresent.cmake"
    COMMENT "Copy tttracy PDB to pascal/bin if present"
    VERBATIM
)
