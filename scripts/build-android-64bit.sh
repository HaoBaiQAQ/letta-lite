#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 定义64位目标架构（全局统一使用）
TARGET_ARCH="aarch64-linux-android"

# 检查必需工具
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

check_command rustup
check_command cargo

# 检查并安装cargo-ndk
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# 检查NDK路径环境变量
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    echo "Please set one of these environment variables to your Android NDK path"
    exit 1
fi
# 统一NDK路径变量
NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 只添加64位目标架构（避免32位冲突）
echo "Adding 64-bit Android target ($TARGET_ARCH)..."
rustup target add "$TARGET_ARCH" || true

# 编译核心库（关键修复：--rustflags 移到 build 后面，作为 cargo build 的参数）
echo "Building for Android ($TARGET_ARCH)..."
export NDK_SYSROOT="$NDK_HOME/sysroot/usr/lib"
# NDK 27默认clang路径（无需动态获取，稳定可靠）
LLVM_LIB_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux/aarch64"
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build \  # 先写 build 命令
    -p letta-ffi --profile mobile \
    --verbose \
    -Z build-std=std,panic_abort \
    -Z build-std-features=panic_immediate_abort \
    --rustflags="-L $NDK_SYSROOT/aarch64-linux-android -L $LLVM_LIB_PATH"  # 移到 build 后面

# 生成C头文件（格式正确，指定架构和profile）
echo "Generating C header (for $TARGET_ARCH)..."
cargo build -p letta-ffi --target "$TARGET_ARCH" --profile mobile
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || true

# 编译64位JNI wrapper（显式链接系统库）
echo "Compiling JNI wrapper (arm64-v8a)..."
# 创建JNI输出目录
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

# JNI编译函数（仅适配arm64-v8a）
compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=24
    
    echo "  Building JNI for $arch..."
    
    # 找到NDK clang编译器
    CLANG_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    "$CLANG_PATH/clang" \
        --target="${triple}${api_level}" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"${NDK_HOME}/sysroot/usr/include" \
        -Iffi/include \
        -shared \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi \
        -llog -lunwind  # 显式链接Android系统库
}

# 检查JNI源文件是否存在，存在则编译
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
else
    echo -e "${YELLOW}Warning: JNI wrapper not found, skipping JNI compilation${NC}"
fi

# 构建AAR（使用官方现成的Gradle配置）
if command -v gradle &> /dev/null || [ -f "bindings/android/gradlew" ]; then
    echo "Building Android AAR (arm64-v8a)..."
    cd bindings/android
    if [ -f "gradlew" ]; then
        ./gradlew assembleRelease
    else
        gradle assembleRelease
    fi
    cd ../..
    
    echo -e "${GREEN}64-bit Android build complete!${NC}"
    echo ""
    echo "AAR location: bindings/android/build/outputs/aar/android-release.aar"
else
    echo -e "${GREEN}64-bit Android libraries built!${NC}"
    echo ""
    echo "Libraries location: bindings/android/src/main/jniLibs/"
fi

echo ""
echo "To use in your Android project:"
echo "1. Add the AAR file to your project's libs folder"
echo "2. Add to your app's build.gradle:"
echo "   implementation files('libs/android-release.aar')"
echo "3. Import in Kotlin: import ai.letta.lite.LettaLite"
