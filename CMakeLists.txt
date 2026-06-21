cmake_minimum_required(VERSION 3.15)
project(Whitted_GI_RayTracer)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(USE_METAL  "Enable Metal backend (macOS only)" ON)
option(USE_OPENGL "Enable OpenGL backend"              ON)
option(USE_VULKAN "Enable Vulkan backend"              OFF)

if(APPLE AND USE_METAL)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)
endif()

# Homebrew prefix for x86 Macs (/usr/local) and Apple Silicon (/opt/homebrew)
if(APPLE)
    if(EXISTS /opt/homebrew)
        set(HOMEBREW_PREFIX /opt/homebrew)
    else()
        set(HOMEBREW_PREFIX /usr/local)
    endif()
    include_directories(${HOMEBREW_PREFIX}/include)
    link_directories(${HOMEBREW_PREFIX}/lib)
endif()

find_package(SDL2 REQUIRED)

# --- Assimp (system install via Homebrew) ---
find_package(assimp REQUIRED)

# --- Bullet (system install via Homebrew) ---
find_package(Bullet REQUIRED)
include_directories(${BULLET_INCLUDE_DIRS})

include(FetchContent)

# --- ImGui ---
FetchContent_Declare(imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG        master
)
FetchContent_MakeAvailable(imgui)

# --- ImGuiFileDialog (compile as plain source — avoids imgui CMake dependency) ---
FetchContent_Declare(ImGuiFileDialog
    GIT_REPOSITORY https://github.com/aiekick/ImGuiFileDialog.git
    GIT_TAG        master
)
FetchContent_GetProperties(ImGuiFileDialog)
if(NOT imguifiledialog_POPULATED)
    FetchContent_Populate(ImGuiFileDialog)
endif()
set(IFDIALOG_DIR ${imguifiledialog_SOURCE_DIR})

# --- STB single-headers ---
set(STB_DIR ${CMAKE_BINARY_DIR}/external/stb)
file(MAKE_DIRECTORY ${STB_DIR})
foreach(HDR stb_image.h stb_image_write.h)
    if(NOT EXISTS "${STB_DIR}/${HDR}")
        file(DOWNLOAD "https://raw.githubusercontent.com/nothings/stb/master/${HDR}"
             "${STB_DIR}/${HDR}" STATUS _dl_status)
    endif()
endforeach()

# --- BVH (header-only C++) ---
FetchContent_Declare(bvh
    GIT_REPOSITORY https://github.com/madmann91/bvh.git
    GIT_TAG        master
)
FetchContent_MakeAvailable(bvh)

set(IMGUI_DIR ${imgui_SOURCE_DIR})
set(BVH_DIR   ${bvh_SOURCE_DIR}/src)

set(IMGUI_SOURCES
    ${IMGUI_DIR}/imgui.cpp
    ${IMGUI_DIR}/imgui_draw.cpp
    ${IMGUI_DIR}/imgui_tables.cpp
    ${IMGUI_DIR}/imgui_widgets.cpp
    ${IMGUI_DIR}/backends/imgui_impl_sdl2.cpp
    ${IFDIALOG_DIR}/ImGuiFileDialog.cpp
)

include_directories(
    includes
    src
    ${IMGUI_DIR}
    ${IMGUI_DIR}/backends
    ${STB_DIR}
    ${BVH_DIR}
    ${IFDIALOG_DIR}
    ${assimp_INCLUDE_DIRS}
)

set(SOURCES
    src/main.cpp
    src/ModelLoader.cpp
    src/Physics.cpp
    ${IMGUI_SOURCES}
)

if(APPLE AND USE_METAL)
    list(APPEND SOURCES
        ${IMGUI_DIR}/backends/imgui_impl_metal.mm
        src/backends/Metal/RendererMetal.mm
    )
    add_definitions(-DUSE_METAL)
endif()

if(USE_OPENGL)
    find_package(OpenGL REQUIRED)
    list(APPEND SOURCES
        ${IMGUI_DIR}/backends/imgui_impl_opengl3.cpp
        src/backends/OpenGL/RendererGL.cpp
    )
    add_definitions(-DUSE_OPENGL)
endif()

if(USE_VULKAN)
    find_package(Vulkan REQUIRED)
    list(APPEND SOURCES
        ${IMGUI_DIR}/backends/imgui_impl_vulkan.cpp
        src/backends/Vulkan/RendererVK.cpp
    )
    add_definitions(-DUSE_VULKAN)
endif()

add_executable(${PROJECT_NAME} ${SOURCES})

target_link_libraries(${PROJECT_NAME} PRIVATE
    ${SDL2_LIBRARIES}
    assimp
    ${BULLET_LIBRARIES}
)

if(APPLE AND USE_METAL)
    find_library(METAL_LIBRARY     Metal)
    find_library(QUARTZCORE_LIBRARY QuartzCore)
    find_library(COCOA_LIBRARY     Cocoa)
    target_link_libraries(${PROJECT_NAME} PRIVATE
        ${METAL_LIBRARY} ${QUARTZCORE_LIBRARY} ${COCOA_LIBRARY}
    )
endif()

if(USE_OPENGL)
    target_link_libraries(${PROJECT_NAME} PRIVATE ${OPENGL_LIBRARIES})
endif()

if(USE_VULKAN)
    target_link_libraries(${PROJECT_NAME} PRIVATE Vulkan::Vulkan)
endif()
