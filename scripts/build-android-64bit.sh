#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 核心配置（简化：指定 API 24，兼容性更广，NDK 必支持）
TARGET_ARCH="aarch64-linux-android"
RUST_TOOLCHAIN="nightly"
FFI_MANIFEST_PATH="ffi/Cargo.toml"
ANDROID_API_LEVEL="24" #  Android 7.0，所有 NDK 版本都支持，避免 API 不匹配

# 检查必需工具
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

check_command rustup
check_command cargo

# 安装并切换到 Nightly 工具链
echo "Installing and switching to Nightly Rust toolchain..."
rustup install "$RUST_TOOLCHAIN"
rustup default "$RUST_TOOLCHAIN"

# 检查并安装cargo-ndk
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# 检查NDK路径环境变量（只确认NDK存在，不手动检查子路径）
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    echo "Please set one of these environment variables to your Android NDK path"
    exit 1
fi
NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 只添加64位目标架构
echo "Adding 64-bit Android target ($TARGET_ARCH)..."
rustup target add "$TARGET_ARCH" || true

# 简化 RUSTFLAGS：只保留 sysroot 核心路径，让 cargo ndk 自动适配平台库
echo "Setting RUSTFLAGS environment variable..."
NDK_SYSROOT_AARCH64="$NDK_HOME/sysroot/usr/lib/aarch64-linux-android" # NDK 必有的路径
LLVM_LIB_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux/aarch64"
OPENSSL_PATH="/home/runner/work/letta-lite/letta-lite/openssl-install/lib"

export RUSTFLAGS="\
-L $NDK_SYSROOT_AARCH64 \
-L $LLVM_LIB_PATH \
-L $OPENSSL_PATH \
-llog \
-lunwind \
"

# 编译核心库（依赖 cargo ndk 自动处理平台库路径，指定 API 24）
echo "Building for Android ($TARGET_ARCH, API $ANDROID_API_LEVEL)..."
cargo +"$RUST_TOOLCHAIN" ndk \
    -t "$TARGET_ARCH" \
    --api "$ANDROID_API_LEVEL" \ # 指定兼容 API，cargo ndk 自动找对应库
    -o bindings/android/src/main/jniLibs \
    -- build \
        --manifest-path "$FFI_MANIFEST_PATH" \
        --profile mobile \
        --target "$TARGET_ARCH"

# 生成C头文件
echo "Generating C header (for $TARGET_ARCH)..."
cargo +"$RUST_TOOLCHAIN" build \
    --manifest-path "$FFI_MANIFEST_PATH" \
    --target "$TARGET_ARCH" \
    --profile mobile

cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || true
echo -e "${YELLOW}Warning: 若找不到 letta_lite.h，可忽略，不影响 AAR 构建${NC}"

# 编译64位JNI wrapper
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=$3
    echo "  Building JNI for $arch (API $api_level)..."
    CLANG_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    "$CLANG_PATH/clang" \
        --target="${triple}-android$api_level" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"$NDK_HOME/sysroot/usr/include" \
        -I"ffi/include" \
        -shared \
        -o "bindings/android/src/main/jniLibs/$arch/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/$arch" \
        -lletta_ffi \
        -L"$NDK_SYSROOT_AARCH64" \ # 用 sysroot 路径找库
        -llog \
        -lunwind
}

if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux" "$ANDROID_API_LEVEL"
else
    echo -e "${YELLOW}Warning: JNI wrapper source file not found, skipping JNI compilation${NC}"
fi

# 构建AAR
if command -v gradle &> /dev/null || [ -f "bindings/android/gradlew" ]; then
    echo "Building Android AAR (arm64-v8a)..."
    cd bindings/android
    [ -f "gradlew" ] && ./gradlew assembleRelease || gradle assembleRelease
    cd ../..
    echo -e "${GREEN}✅ 64-bit Android AAR 构建成功！${NC}"
    echo "📁 AAR 路径: bindings/android/build/outputs/aar/android-release.aar"
else
    echo -e "${GREEN}✅ 64-bit Android 库构建成功！${NC}"
    echo "📁 库路径: bindings/android/src/main/jniLibs/"
fi

echo ""
echo "📱 后续使用："
echo "1. 下载 AAR 文件到 Android 项目的 libs 文件夹；"
echo "2. 在 app/build.gradle 中添加：implementation files('libs/android-release.aar')；"
echo "3. 直接调用 Letta-Lite 的核心功能（对话、记忆管理等）。"
