cmake_minimum_required(VERSION 3.22.1)

project(workbench_lc3 LANGUAGES C CXX)

set(LIBLC3_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/liblc3")

add_library(
    workbench_lc3
    SHARED
    workbench_lc3.cpp
    "${LIBLC3_DIR}/src/attdet.c"
    "${LIBLC3_DIR}/src/bits.c"
    "${LIBLC3_DIR}/src/bwdet.c"
    "${LIBLC3_DIR}/src/energy.c"
    "${LIBLC3_DIR}/src/lc3.c"
    "${LIBLC3_DIR}/src/ltpf.c"
    "${LIBLC3_DIR}/src/mdct.c"
    "${LIBLC3_DIR}/src/plc.c"
    "${LIBLC3_DIR}/src/sns.c"
    "${LIBLC3_DIR}/src/spec.c"
    "${LIBLC3_DIR}/src/tables.c"
    "${LIBLC3_DIR}/src/tns.c"
)

target_include_directories(
    workbench_lc3
    PRIVATE
    "${LIBLC3_DIR}/include"
    "${LIBLC3_DIR}/src"
)

target_compile_options(workbench_lc3 PRIVATE -O3 -ffast-math)

find_library(log_library log)
target_link_libraries(workbench_lc3 PRIVATE "${log_library}")
