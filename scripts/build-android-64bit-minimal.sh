#!/usr/bin/env bash
set -euo pipefail

# 🔧 强制仅编译64位架构，彻底禁用32位，避免冲突
export CARGO_TARGET=aarch64-linux-android
export ANDROID_ABI=arm64-v8a

echo "Building Letta Lite for Android (64-bit only)..."

# 原作者颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 原作者工具检查
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo

# 🔧 关键修复1：显式获取当前活跃的 Rust 工具链（避免工具链不匹配）
ACTIVE_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
echo -e "✅ Active Rust toolchain: ${ACTIVE_TOOLCHAIN}"

# 🔧 安装 cbindgen（原作者 build.rs 用的工具，直接手动调用）
if ! command -v cbindgen &> /dev/null; then
    echo -e "${YELLOW}Installing cbindgen (for generating C header)...${NC}"
    cargo install cbindgen
fi

# 原作者cargo-ndk安装（用原作者方式，不指定版本避免冲突）
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# 原作者NDK路径检查
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-${ANDROID_NDK_HOME:-}}"

# 🔧 关键修复2：显式指定工具链安装目标，验证路径
echo "Adding Android 64-bit target (aarch64-linux-android) to ${ACTIVE_TOOLCHAIN}..."
rustup target add aarch64-linux-android --toolchain "${ACTIVE_TOOLCHAIN}"
if ! rustup target list --toolchain "${ACTIVE_TOOLCHAIN}" | grep -q "aarch64-linux-android (installed)"; then
    echo -e "${RED}Error: aarch64-linux-android target not installed for ${ACTIVE_TOOLCHAIN}${NC}"
    exit 1
fi
RUSTLIB_PATH="$HOME/.rustup/toolchains/${ACTIVE_TOOLCHAIN}/lib/rustlib/${CARGO_TARGET}"
if [ ! -d "${RUSTLIB_PATH}" ]; then
    echo -e "${RED}Error: RUSTLIB path not found: ${RUSTLIB_PATH}${NC}"
    exit 1
fi
export RUSTLIB="${RUSTLIB_PATH}"
echo -e "${GREEN}✅ RUSTLIB set to: ${RUSTLIB_PATH}${NC}"

# 🔧 仅编译64位核心库（已成功生成 libletta_ffi.so，复用成果！）
echo "Building Letta FFI (64-bit)..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose

# 🔧 修正：去掉多余的 --config 参数，用默认配置生成头文件（原作者无自定义配置）
echo "Generating C header (aarch64 architecture)..."
cbindgen \
    --lang c \  # 生成C语言头文件（JNI需要）
    --output bindings/android/src/main/jni/letta_lite.h \  # 输出到JNI目录，直接用
    ffi/src/lib.rs  # Rust源码入口（和原作者 build.rs 一致）
if [ -f "bindings/android/src/main/jni/letta_lite.h" ]; then
    echo -e "${GREEN}✅ C header generated successfully: bindings/android/src/main/jni/letta_lite.h${NC}"
else
    echo -e "${RED}❌ Failed to generate C header${NC}"
    exit 1
fi

# 🔧 仅编译64位JNI（原作者编译逻辑不变）
echo "Compiling JNI wrapper (64-bit)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=21
    
    echo "  Building JNI for $arch..."
    "${NDK_HOME}"/toolchains/llvm/prebuilt/*/bin/clang \
        --target="${triple}${api_level}" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"${NDK_HOME}/sysroot/usr/include" \
        -Ibindings/android/src/main/jni/ \  # 引用生成的头文件
        -shared \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi  # 链接已生成的核心库
}

if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
else
    echo -e "${RED}Error: JNI wrapper (letta_jni.c) not found${NC}"
    exit 1
fi

# 原作者AAR构建逻辑（现在不会被打断，能正常执行）
echo "Building Android AAR..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --verbose --stacktrace
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ gradlew assembleRelease failed${NC}"
        exit 1
    fi
else
    gradle assembleRelease --verbose --stacktrace
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ gradle assembleRelease failed${NC}"
        exit 1
    fi
fi
cd ../..

# 🔧 验证产物（确保SO和AAR都生成）
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
SO_PATH="bindings/android/src/main/jniLibs/arm64-v8a/libletta_jni.so"
if [ -f "$AAR_PATH" ] && [ -f "$SO_PATH" ]; then
    echo -e "${GREEN}✅ Build successful!${NC}"
    echo "AAR: $AAR_PATH"
    echo "SO: $SO_PATH"
else
    echo -e "${RED}❌ Build failed: 产物缺失${NC}"
    echo "AAR exists? $(test -f "$AAR_PATH" && echo "Yes" || echo "No")"
    echo "SO exists? $(test -f "$SO_PATH" && echo "Yes" || echo "No")"
    exit 1
fi
