set prefix=%cd%\deps_build
git submodule update --init --recursive --depth 1 --recommend-shallow

:: libdovi:
cd deps\dovi_tool\dolby_vision || exit /b
cargo install cargo-c
cargo cinstall --release --prefix %prefix% || exit /b

:: libplacebo:
cd ..\..\libplacebo || exit /b
git apply ..\libplacebo_meson.patch

call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
echo %LIB%
set INCLUDE=%INCLUDE%;%VULKAN_SDK%\Include;%prefix%\include
set LIB=%LIB%;%VULKAN_SDK%\Lib;%prefix%\lib

set CC=clang-cl
set CXX=clang-cl

meson setup build -Dvulkan-registry=%VULKAN_SDK%\share\vulkan\registry\vk.xml --default-library=static --buildtype=release -Ddemos=false -Dopengl=disabled -Dd3d11=disabled --prefix=%prefix% --wipe
ninja -C build
ninja -C build install

zig build -Doptimize=ReleaseFast