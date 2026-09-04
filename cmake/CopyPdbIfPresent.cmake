# cmake -Dsrc=... -Dbase=... -Ddst=... -P CopyPdbIfPresent.cmake
if (NOT src OR NOT base OR NOT dst)
    message(FATAL_ERROR "CopyPdbIfPresent: src, base, dst required")
endif()
set(_pdb "${src}/${base}.pdb")
if (EXISTS "${_pdb}")
    file(MAKE_DIRECTORY "${dst}")
    file(COPY "${_pdb}" DESTINATION "${dst}")
endif()
