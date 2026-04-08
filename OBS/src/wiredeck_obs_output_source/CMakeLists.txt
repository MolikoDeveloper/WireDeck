cmake_minimum_required(VERSION 3.28)

project(wiredeck_obs_output_source LANGUAGES C CXX)

find_package(libobs REQUIRED)

add_library(wiredeck_obs_output_source MODULE
    plugin-main.cpp
)

target_compile_features(wiredeck_obs_output_source PRIVATE cxx_std_17)
target_include_directories(wiredeck_obs_output_source PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(wiredeck_obs_output_source PRIVATE OBS::libobs)

if(WIN32)
    target_link_libraries(wiredeck_obs_output_source PRIVATE ws2_32)
endif()

set_target_properties(wiredeck_obs_output_source PROPERTIES
    PREFIX ""
    OUTPUT_NAME "wiredeck_obs_output_source"
)
