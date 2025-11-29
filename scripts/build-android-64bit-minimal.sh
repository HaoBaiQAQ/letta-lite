#!/usr/bin/env bash
set -euo pipefail

# 第一步：定义变量（精简+NDK 自带库路径）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 核心路径（依赖 NDK 自带库，去掉手动 unwind 路径）
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"
export JNI_LIBS_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs"
export FFI_INCLUDE_DIR="${PWD}/ffi/include"
export OPENSSL_DIR="${OPENSSL_DIR:-/home/runner/work/letta-lite/openssl-install}"
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/aarch64-linux-android/lib"
export NDK_HOME="${NDK_HOME:-/usr/local/lib/android/sdk/ndk/27.3.13750724}"
# 🔧 关键：NDK 自带 libunwind 路径（AArch64 架构，API 24）
export NDK_UNWIND_PATH="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24"

echo -e "\n${YELLOW}=== 依赖 NDK 自带 libunwind + 标准库路径修复 ===${NC}"

# 工具检查
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: 缺失工具 $1${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command clang
check_command cbindgen

# 安装 cargo-ndk
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}安装 cargo-ndk...${NC}"
    cargo install cargo-ndk --version=3.5.4 --locked
fi

# 验证目标平台和标准库
echo -e "\n${YELLOW}验证目标平台和依赖路径...${NC}"
if ! rustup target list | grep -q "aarch64-linux-android (installed)"; then
    echo -e "${YELLOW}安装 aarch64-linux-android 目标...${NC}"
    rustup target add aarch64-linux-android --toolchain stable || exit 1
fi
[ ! -d "$RUST_STD_PATH" ] && { echo -e "${RED}Rust 标准库路径不存在！${NC}"; exit 1; }
[ ! -d "$NDK_UNWIND_PATH" ] && { echo -e "${RED}NDK libunwind 路径不存在：$NDK_UNWIND_PATH${NC}"; exit 1; }
# 验证 NDK 自带 libunwind 是否存在
if [ ! -f "${NDK_UNWIND_PATH}/libunwind.a" ] && [ ! -f "${NDK_UNWIND_PATH}/libunwind.so" ]; then
    echo -e "${RED}Error: NDK 自带 libunwind 库缺失！${NC}"
    ls -l "$NDK_UNWIND_PATH"  # 打印目录内容排查
    exit 1
fi
echo -e "${GREEN}✅ 所有依赖路径验证通过${NC}"

# 🔧 核心配置：RUSTFLAGS 包含 NDK 自带 libunwind 路径
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export RUSTFLAGS="\
--sysroot=${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot \
-L $RUST_STD_PATH \
-L $NDK_UNWIND_PATH \  # 优先用 NDK 自带 libunwind
-L ${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24 \
-lunwind -ldl -llog -lm -lc \
-C link-arg=--allow-shlib-undefined \
-C linker=${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/ld.lld"

# 编译 Rust 核心库（cargo ndk + NDK 自带 libunwind）
echo -e "\n${YELLOW}=== 编译 Rust 核心库 ===${NC}"
cargo clean -p letta-ffi --target aarch64-linux-android || true  # 清除旧缓存
cargo ndk \
    -t arm64-v8a \
    -o "$JNI_LIBS_DIR" \
    build -p letta-ffi --profile mobile --verbose
CORE_SO="${JNI_LIBS_DIR}/arm64-v8a/libletta_ffi.so"
[ ! -f "$CORE_SO" ] && { echo -e "${RED}核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：$CORE_SO${NC}"

# 生成 C 头文件
echo -e "\n${YELLOW}=== 生成 C 头文件 ===${NC}"
mkdir -p "$FFI_INCLUDE_DIR" "${ANDROID_PROJECT_DIR}/src/main/jni"
cbindgen --crate letta-ffi --lang c --output "${FFI_INCLUDE_DIR}/letta_lite.h"
cp "${FFI_INCLUDE_DIR}/letta_lite.h" "${ANDROID_PROJECT_DIR}/src/main/jni/"
echo -e "${GREEN}✅ 头文件生成成功${NC}"

# 编译 JNI 库（使用 NDK 自带 libunwind）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
local arch="arm64-v8a"
local triple="aarch64-linux-android"
local api_level=24
"${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" \
    --target="${triple}${api_level}" \
    --sysroot="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"$FFI_INCLUDE_DIR" \
    -I"${OPENSSL_INCLUDE_DIR}" \
    -shared -fPIC -o "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" \
    "${ANDROID_PROJECT_DIR}/src/main/jni/letta_jni.c" \
    -L"${JNI_LIBS_DIR}/${arch}" \
    -L"${OPENSSL_LIB_DIR}" \
    -L "$NDK_UNWIND_PATH" \  # JNI 编译也用 NDK 自带 libunwind
    -lletta_ffi \
    -lssl -lcrypto \
    -lunwind -ldl -llog -lm -lc
[ ! -f "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" ] && { echo -e "${RED}JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功${NC}"

# 打包 AAR
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd "$ANDROID_PROJECT_DIR" || { echo -e "${RED}进入 Android 目录失败${NC}"; exit 1; }
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
else
    echo -e "${YELLOW}使用系统 gradle 兼容模式${NC}"
    gradle assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" -Dorg.gradle.unsafe.configuration-cache=false
fi
cd - > /dev/null

# 收集产物
AAR_PATH="${ANDROID_PROJECT_DIR}/build/outputs/aar/android-release.aar"
if [ ! -f "$AAR_PATH" ]; then
    AAR_FILE=$(find "$ANDROID_PROJECT_DIR" -name "*.aar" | grep -E "release" | head -n 1)
    [ -z "$AAR_FILE" ] && { echo -e "${RED}AAR 打包失败（请确认 gradlew 完整）${NC}"; exit 1; }
    AAR_PATH="$AAR_FILE"
fi

mkdir -p "${PWD}/release"
cp "$CORE_SO" "${PWD}/release/"
cp "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" "${PWD}/release/"
cp "$AAR_PATH" "${PWD}/release/letta-lite-android.aar"
cp "${FFI_INCLUDE_DIR}/letta_lite.h" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27${NC}"
ls -l "${PWD}/release/"
