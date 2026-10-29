# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)
set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

function(download_and_extract url sha256 archive destination)
  if(EXISTS "${archive}")
    file(SHA256 "${archive}" actual)
    if(NOT actual STREQUAL sha256)
      file(REMOVE "${archive}")
    endif()
  endif()
  if(NOT EXISTS "${archive}")
    file(DOWNLOAD "${url}" "${archive}.partial"
      EXPECTED_HASH "SHA256=${sha256}" TLS_VERIFY ON
      TIMEOUT 300 INACTIVITY_TIMEOUT 30 STATUS result)
    list(GET result 0 code)
    if(NOT code EQUAL 0)
      file(REMOVE "${archive}.partial")
      message(FATAL_ERROR "依赖下载失败：${result}")
    endif()
    file(RENAME "${archive}.partial" "${archive}")
  endif()
  set(stamp "${destination}/.archive-sha256")
  set(extracted "")
  if(EXISTS "${stamp}")
    file(READ "${stamp}" extracted)
  endif()
  if(NOT extracted STREQUAL sha256)
    file(REMOVE_RECURSE "${destination}")
    file(MAKE_DIRECTORY "${destination}")
    execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${archive}"
      WORKING_DIRECTORY "${destination}" RESULT_VARIABLE code)
    if(NOT code EQUAL 0)
      message(FATAL_ERROR "依赖解压失败：${archive}")
    endif()
    file(WRITE "${stamp}" "${sha256}")
  endif()
endfunction()

set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")
# 必须用 media-kit 自建的视频专用精简版（libmpv-2.dll 为 36 MB），即上游
# media_kit_libs_windows_video 1.0.11 指定的那一份。换成 shinchiro 的全功能版后
# 同一个 DLL 有 115 MB（.text 段就 93 MB，无调试符号可剥），Windows 安装包翻一倍
download_and_extract(
  "https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/mpv-dev-x86_64-20241021-git-0f78584.7z"
  "e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007"
  "${CMAKE_BINARY_DIR}/mpv-dev-x86_64-20241021.7z" "${LIBMPV_SRC}")
if(EXISTS "${LIBMPV_SRC}/include/mpv/client.h")
  file(COPY "${LIBMPV_SRC}/include/mpv/" DESTINATION "${LIBMPV_SRC}/include")
endif()

set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")
download_and_extract(
  "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
  "cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a"
  "${CMAKE_BINARY_DIR}/ANGLE.7z" "${ANGLE_SRC}")

set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_video_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  "${ANGLE_SRC}/d3dcompiler_47.dll"
  "${ANGLE_SRC}/libEGL.dll"
  "${ANGLE_SRC}/libGLESv2.dll"
  "${ANGLE_SRC}/vk_swiftshader.dll"
  "${ANGLE_SRC}/vulkan-1.dll"
  "${ANGLE_SRC}/zlib.dll"
  PARENT_SCOPE
)
