find_path(SIMDe_INCLUDE_DIR
    NAMES
        simde/simde-arch.h
        simde/x86/sse2.h
    PATHS
        /opt/homebrew/include
        /usr/local/include
)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(SIMDe DEFAULT_MSG SIMDe_INCLUDE_DIR)

if(SIMDe_FOUND AND NOT TARGET SIMDe::SIMDe)
    add_library(SIMDe::SIMDe INTERFACE IMPORTED)
    set_target_properties(SIMDe::SIMDe PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${SIMDe_INCLUDE_DIR}"
    )
endif()
