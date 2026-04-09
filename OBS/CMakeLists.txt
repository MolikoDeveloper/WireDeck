cmake_minimum_required(VERSION 3.28)

project(wiredeck_obs_plugins LANGUAGES C CXX)

list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

add_subdirectory(src/wiredeck_obs_output_source)
