# Invoked as cmake -P after linking. Converts DWARF in BIN using CV2PDB.
if (NOT CFG MATCHES "^(Debug|Profile|RelWithDebInfo)$")
    return()
endif()
if (NOT CV2PDB OR NOT BIN)
    message(FATAL_ERROR "RunCv2pdb: CV2PDB and BIN are required")
endif()
if (NOT EXISTS "${BIN}")
    message(FATAL_ERROR "RunCv2pdb: missing ${BIN}")
endif()
set(_vswhere "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe")
if (EXISTS "${_vswhere}")
    execute_process(
        COMMAND "${_vswhere}" -latest -products * -property installationPath
        OUTPUT_VARIABLE _vs
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if (_vs)
        set(ENV{PATH} "${_vs}/Common7/IDE;$ENV{PATH}")
    endif()
endif()
get_filename_component(_dir "${BIN}" DIRECTORY)
get_filename_component(_name "${BIN}" NAME_WE)
set(_pdb "${_dir}/${_name}.pdb")
# cv2pdb 0.54: <exe> [new-exe] [pdb]. -C C++ names, -n new PDB. In-place PE.
execute_process(
    COMMAND "${CV2PDB}" -C -n "${BIN}" "${BIN}" "${_pdb}"
    WORKING_DIRECTORY "${_dir}"
    RESULT_VARIABLE _rc
    ERROR_VARIABLE _err
    OUTPUT_VARIABLE _out
)
if (NOT _rc EQUAL 0)
    message(FATAL_ERROR "cv2pdb failed (${_rc}) for ${BIN}\n${_out}${_err}")
endif()
if (NOT EXISTS "${_pdb}")
    message(FATAL_ERROR "cv2pdb produced no PDB: ${_pdb}\n${_out}${_err}")
endif()
if (_out OR _err)
    message(STATUS "cv2pdb ${BIN} -> ${_pdb}\n${_out}${_err}")
endif()
