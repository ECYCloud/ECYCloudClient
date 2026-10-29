cmake_minimum_required(VERSION 3.14)
project(windows_runner_tests LANGUAGES CXX)

enable_testing()
set(FLUTTER_EPHEMERAL "${CMAKE_CURRENT_SOURCE_DIR}/../../flutter/ephemeral")
add_executable(gpu_watchdog_test gpu_watchdog_test.cpp)
add_executable(window_lifecycle_test
  window_lifecycle_test.cpp
  ../flutter_window.cpp
  ../gpu_watchdog.cpp
  ../platform_channel.cpp
  ../utils.cpp
  ../win32_window.cpp
  "${FLUTTER_EPHEMERAL}/cpp_client_wrapper/core_implementations.cc"
  "${FLUTTER_EPHEMERAL}/cpp_client_wrapper/standard_codec.cc"
  "${FLUTTER_EPHEMERAL}/cpp_client_wrapper/flutter_engine.cc"
  "${FLUTTER_EPHEMERAL}/cpp_client_wrapper/flutter_view_controller.cc"
)
target_compile_definitions(window_lifecycle_test PRIVATE
  ECYCLOUD_DISPLAY_VERSION="test"
)
target_link_libraries(window_lifecycle_test PRIVATE dxgi dwmapi imm32 comctl32 shell32)

foreach(target gpu_watchdog_test window_lifecycle_test)
  target_compile_features(${target} PRIVATE cxx_std_17)
  target_compile_definitions(${target} PRIVATE NOMINMAX UNICODE _UNICODE)
  target_compile_options(${target} PRIVATE /W4 /WX /wd4100 /utf-8 /EHsc)
  target_include_directories(${target} PRIVATE
    ../..
    "${FLUTTER_EPHEMERAL}"
    "${FLUTTER_EPHEMERAL}/cpp_client_wrapper/include"
  )
  target_link_libraries(${target} PRIVATE
    "${FLUTTER_EPHEMERAL}/flutter_windows.dll.lib"
    d3d11
  )
  add_custom_command(TARGET ${target} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${FLUTTER_EPHEMERAL}/flutter_windows.dll"
      "$<TARGET_FILE_DIR:${target}>"
  )
  add_test(NAME ${target} COMMAND ${target})
endforeach()
