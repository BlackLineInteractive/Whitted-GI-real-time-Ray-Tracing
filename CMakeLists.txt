cmake_minimum_required(VERSION 3.15)
project(Whitted_GI_RayTracer)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(USE_METAL "Enable Metal backend (macOS only)" ON)
option(USE_OPENGL "Enable OpenGL backend" ON)
option(USE_VULKAN "Enable Vulkan backend" ON)

if(APPLE AND USE_METAL)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 17)
endif()

find_package(SDL2 REQUIRED)

include(FetchContent)

# --- Fetch external dependencies automatically ---
FetchContent_Declare(
    imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG master
)
FetchContent_MakeAvailable(imgui)

# Fetch STB (single header instead of full repo)
set(STB_DIR ${CMAKE_BINARY_DIR}/external/stb)
file(MAKE_DIRECTORY ${STB_DIR})
if(NOT EXISTS "${STB_DIR}/stb_image.h")
    file(DOWNLOAD "https://raw.githubusercontent.com/nothings/stb/master/stb_image.h" "${STB_DIR}/stb_image.h")
endif()
if(NOT EXISTS "${STB_DIR}/stb_image_write.h")
    file(DOWNLOAD "https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h" "${STB_DIR}/stb_image_write.h")
endif()

FetchContent_Declare(
    bvh
    GIT_REPOSITORY https://github.com/svenstaro/bvh.git
    GIT_TAG master
)
FetchContent_MakeAvailable(bvh)
# -------------------------------------------------

set(IMGUI_DIR ${imgui_SOURCE_DIR})
set(BVH_DIR ${bvh_SOURCE_DIR}/include)

set(IMGUI_SOURCES
    ${IMGUI_DIR}/imgui.cpp
    ${IMGUI_DIR}/imgui_draw.cpp
    ${IMGUI_DIR}/imgui_tables.cpp
    ${IMGUI_DIR}/imgui_widgets.cpp
    ${IMGUI_DIR}/backends/imgui_impl_sdl2.cpp
)

include_directories(
    includes
    src
    ${IMGUI_DIR}
    ${IMGUI_DIR}/backends
    ${STB_DIR}
    ${BVH_DIR}
)

set(SOURCES
    src/main.cpp
    ${IMGUI_SOURCES}
)

if(APPLE AND USE_METAL)
    list(APPEND SOURCES ${IMGUI_DIR}/backends/imgui_impl_metal.mm src/backends/Metal/RendererMetal.mm)
    add_definitions(-DUSE_METAL)
endif()

if(USE_OPENGL)
    find_package(OpenGL REQUIRED)
    list(APPEND SOURCES ${IMGUI_DIR}/backends/imgui_impl_opengl3.cpp src/backends/OpenGL/RendererGL.cpp)
    add_definitions(-DUSE_OPENGL)
endif()

if(USE_VULKAN)
    find_package(Vulkan REQUIRED)
    list(APPEND SOURCES ${IMGUI_DIR}/backends/imgui_impl_vulkan.cpp src/backends/Vulkan/RendererVK.cpp)
    add_definitions(-DUSE_VULKAN)
endif()

add_executable(${PROJECT_NAME} ${SOURCES})

target_link_libraries(${PROJECT_NAME} PRIVATE ${SDL2_LIBRARIES})

if(APPLE AND USE_METAL)
    find_library(METAL_LIBRARY Metal)
    find_library(QUARTZCORE_LIBRARY QuartzCore)
    find_library(COCOA_LIBRARY Cocoa)
    target_link_libraries(${PROJECT_NAME} PRIVATE ${METAL_LIBRARY} ${QUARTZCORE_LIBRARY} ${COCOA_LIBRARY})
endif()

if(USE_OPENGL)
    target_link_libraries(${PROJECT_NAME} PRIVATE ${OPENGL_LIBRARIES})
endif()

if(USE_VULKAN)
    target_link_libraries(${PROJECT_NAME} PRIVATE Vulkan::Vulkan)
endif()
