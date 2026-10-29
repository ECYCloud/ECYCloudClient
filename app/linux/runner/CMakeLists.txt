cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "platform_channel.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")

# 界面展示的版本串。Pre 通道形如「Pre 1.0.3」，而 --build-name 必须是纯号段
# （deb / rpm 版本字段只接受数字），两者不同源：出包脚本用环境变量把展示串带进来
if(DEFINED ENV{ECYCLOUD_VERSION})
  set(DISPLAY_VERSION "$ENV{ECYCLOUD_VERSION}")
else()
  set(DISPLAY_VERSION "${FLUTTER_VERSION}")
endif()
target_compile_definitions(${BINARY_NAME} PRIVATE "ECYCLOUD_DISPLAY_VERSION=\"${DISPLAY_VERSION}\"")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::APPINDICATOR)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::LIBSECRET)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
