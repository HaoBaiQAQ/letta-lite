#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 核心配置（去掉 --api 参数，用环境变量替代）
TARGET_ARCH="aarch64-linux-android"
RUST_TOOLCHAIN="nightly"
FFI_MANIFEST_PATH="ffi/Cargo.toml"
ANDROID_API_LEVEL="24" # 用环境变量传递给正确的 cargo-ndk

# 检查必需工具
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo

# 关键步骤1：卸载假的 cargo-ndk（v4.1.2），安装真的 cargo-ndk（0.11.0，支持 Android）
echo "Uninstalling wrong cargo-ndk (v4.1.2) and installing correct one..."
cargo uninstall cargo-ndk 2>/dev/null || echo -e "${YELLOW}No wrong cargo-ndk found, proceeding...${NC}"
# 安装正确的版本（0.11.0，官方稳定版，支持 --api 或环境变量）
cargo install cargo-ndk@0.11.0 --force

# 切换到 Nightly 工具链
echo "Installing and switching to Nightly Rust toolchain..."
rustup install "$RUST_TOOLCHAIN"
rustup default "$RUST_TOOLCHAIN"

# 检查NDK路径
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    exit 1
fi
NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 添加目标架构
echo "Adding 64-bit Android target ($TARGET_ARCH)..."
rustup target add "$TARGET_ARCH" || true

# 设置 RUSTFLAGS 和 Android API 环境变量（替代 --api 参数）
echo "Setting environment variables..."
NDK_SYSROOT_AARCH64="$NDK_HOME/sysroot/usr/lib/aarch64-linux-android"
LLVM_LIB_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux/aarch64"
OPENSSL_PATH="/home/runner/work/letta-lite/letta-lite/openssl-install/lib"
export RUSTFLAGS="-L $NDK_SYSROOT_AARCH64 -L $LLVM_LIB_PATH -L $OPENSSL_PATH -llog -lunwind"
export ANDROID_API_LEVEL="$ANDROID_API_LEVEL" # 用环境变量传递 API 级别，避免 --api 参数

# 编译核心库（去掉 --api 参数，用环境变量替代；确保是正确的 cargo-ndk）
echo "Building for Android ($TARGET_ARCH, API $ANDROID_API_LEVEL)..."
cargo ndk -t "$TARGET_ARCH" -o bindings/android/src/main/jniLibs -- build --manifest-path "$FFI_MANIFEST_PATH" --profile mobile --target "$TARGET_ARCH"

# 生成C头文件
echo "Generating C header (for $TARGET_ARCH)..."
cargo build --manifest-path "$FFI_MANIFEST_PATH" --target "$TARGET_ARCH" --profile mobile
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || echo -e "${YELLOW}Warning: letta_lite.h not found, skipping${NC}"

# 编译JNI wrapper
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a
compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=$3
    echo "  Building JNI for $arch (API $api_level)..."
    CLANG_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    "$CLANG_PATH/clang" --target="${triple}-android$api_level" -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" -I"$NDK_HOME/sysroot/usr/include" -I"ffi/include" -shared -o "bindings/android/src/main/jniLibs/$arch/libletta_jni.so" bindings/android/src/main/jni/letta_jni.c -L"bindings/android/src/main/jniLibs/$arch" -lletta_ffi -L"$NDK_SYSROOT_AARCH64" -llog -lunwind
}
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux" "$ANDROID_API_LEVEL"
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
