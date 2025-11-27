#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 核心配置（只保留必要项，其余让 cargo-ndk 自动处理）
TARGET_ARCH="aarch64-linux-android"
RUST_TOOLCHAIN="nightly"
FFI_MANIFEST_PATH="ffi/Cargo.toml"
ANDROID_API_LEVEL="24"

# 检查必需工具
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo

# 确保安装的是官方 cargo-ndk（Android 专用）
echo "Ensuring official cargo-ndk is installed..."
cargo uninstall cargo-ndk 2>/dev/null || true
cargo install cargo-ndk --force

# 切换到 Nightly 工具链
echo "Installing and switching to Nightly Rust toolchain..."
rustup install "$RUST_TOOLCHAIN"
rustup default "$RUST_TOOLCHAIN"

# 检查NDK路径（只确认NDK存在，不手动干预子路径）
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}" # 暴露给 cargo-ndk 读取

# 添加目标架构（cargo-ndk 依赖此目标）
echo "Adding 64-bit Android target ($TARGET_ARCH)..."
rustup target add "$TARGET_ARCH" || true

# 关键：只保留 OpenSSL 路径（非系统库，需手动指定），其余让 cargo-ndk 自动处理
echo "Setting RUSTFLAGS (only OpenSSL path)..."
OPENSSL_PATH="/home/runner/work/letta-lite/letta-lite/openssl-install/lib"
export RUSTFLAGS="-L $OPENSSL_PATH" # 去掉所有 NDK 系统路径，让 cargo-ndk 自动加

# 核心：让 cargo-ndk 全程接管，去掉 --target 参数（cargo-ndk 已自动指定）
# 修正：删除行末尾的 # 注释，确保每行末尾只有 \
echo "Building for Android ($TARGET_ARCH, API $ANDROID_API_LEVEL)..."
cargo ndk \
    -t "$TARGET_ARCH" \
    --api "$ANDROID_API_LEVEL" \
    -o bindings/android/src/main/jniLibs \
    -- build \
        --manifest-path "$FFI_MANIFEST_PATH" \
        --profile mobile

# 生成C头文件（同样让 cargo-ndk 自动处理目标）
echo "Generating C header (for $TARGET_ARCH)..."
cargo ndk -t "$TARGET_ARCH" --api "$ANDROID_API_LEVEL" -- build \
    --manifest-path "$FFI_MANIFEST_PATH" \
    --profile mobile

cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || echo -e "${YELLOW}Warning: letta_lite.h not found, skipping${NC}"

# 编译JNI wrapper（用 NDK 自带的 clang 链接器）
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a
compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=$3
    echo "  Building JNI for $arch (API $api_level)..."
    # 用 NDK 自带的 aarch64-linux-android-clang，确保能找到系统库
    CLANG_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/$triple$api_level-clang"
    "$CLANG_PATH" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"$NDK_HOME/sysroot/usr/include" \
        -I"ffi/include" \
        -shared \
        -o "bindings/android/src/main/jniLibs/$arch/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/$arch" \
        -lletta_ffi \
        -llog \
        -lunwind
}
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android" "$ANDROID_API_LEVEL"
else
    echo -e "${YELLOW}Warning: JNI source file not found, skipping${NC}"
fi

# 构建AAR
if command -v gradle &> /dev/null || [ -f "bindings/android/gradlew" ]; then
    echo "Building Android AAR (arm64-v8a)..."
    cd bindings/android && ([ -f "gradlew" ] && ./gradlew assembleRelease || gradle assembleRelease) && cd ../..
    echo -e "${GREEN}✅ 64-bit Android AAR built successfully!${NC}"
    echo "📁 AAR Path: bindings/android/build/outputs/aar/android-release.aar"
else
    echo -e "${GREEN}✅ 64-bit Android library built successfully!${NC}"
    echo "📁 Library Path: bindings/android/src/main/jniLibs/"
fi

echo ""
echo "📱 Usage Guide:"
echo "1. Download the AAR file to your Android project's 'libs' folder;"
echo "2. Add to app/build.gradle: implementation files('libs/android-release.aar');"
echo "3. Call Letta-Lite core functions (conversation, memory management, etc.)."
