#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 核心配置
TARGET_ARCH="aarch64-linux-android"
RUST_TOOLCHAIN="nightly"
FFI_MANIFEST_PATH="ffi/Cargo.toml"
ANDROID_API_LEVEL="24" # 兼容所有 NDK 版本

# 检查必需工具
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

check_command rustup
check_command cargo

# 安装并切换到 Nightly 工具链（提前切换，避免命令行参数混合）
echo "Installing and switching to Nightly Rust toolchain..."
rustup install "$RUST_TOOLCHAIN"
rustup default "$RUST_TOOLCHAIN" # 提前切换，命令行不再带 +nightly

# 检查并安装cargo-ndk
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# 检查NDK路径
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    exit 1
fi
NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 添加64位目标架构
echo "Adding 64-bit Android target ($TARGET_ARCH)..."
rustup target add "$TARGET_ARCH" || true

# 设置 RUSTFLAGS（简化路径，依赖 cargo ndk 自动适配）
echo "Setting RUSTFLAGS environment variable..."
NDK_SYSROOT_AARCH64="$NDK_HOME/sysroot/usr/lib/aarch64-linux-android"
LLVM_LIB_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux/aarch64"
OPENSSL_PATH="/home/runner/work/letta-lite/letta-lite/openssl-install/lib"

export RUSTFLAGS="\
-L $NDK_SYSROOT_AARCH64 \
-L $LLVM_LIB_PATH \
-L $OPENSSL_PATH \
-llog \
-lunwind \
"

# 核心修正：提前切换工具链，命令行不带 +nightly；参数按官方顺序排序
echo "Building for Android ($TARGET_ARCH, API $ANDROID_API_LEVEL)..."
cargo ndk \
    -t "$TARGET_ARCH" \ # 1. 目标架构
    --api "$ANDROID_API_LEVEL" \ # 2. API级别（紧跟 -t，确保被识别）
    -o bindings/android/src/main/jniLibs \ # 3. 输出路径
    -- build \ # 4. 分隔符 + cargo build 命令
        --manifest-path "$FFI_MANIFEST_PATH" \
        --profile mobile \
        --target "$TARGET_ARCH"

# 生成C头文件
echo "Generating C header (for $TARGET_ARCH)..."
cargo build \
    --manifest-path "$FFI_MANIFEST_PATH" \
    --target "$TARGET_ARCH" \
    --profile mobile

cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || true
echo -e "${YELLOW}Warning: 若找不到 letta_lite.h，可忽略${NC}"

# 编译JNI wrapper
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
        -L"$NDK_SYSROOT_AARCH64" \
        -llog \
        -lunwind
}

if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux" "$ANDROID_API_LEVEL"
else
    echo -e "${YELLOW}Warning: JNI源文件未找到，跳过${NC}"
fi

# 构建AAR
if command -v gradle &> /dev/null || [ -f "bindings/android/gradlew" ]; then
    echo "Building Android AAR (arm64-v8a)..."
    cd bindings/android
    [ -f "gradlew" ] && ./gradlew assembleRelease || gradle assembleRelease
    cd ../..
    echo -e "${GREEN}✅ AAR构建成功！${NC}"
    echo "📁 路径: bindings/android/build/outputs/aar/android-release.aar"
else
    echo -e "${GREEN}✅ 库文件构建成功！${NC}"
    echo "📁 路径: bindings/android/src/main/jniLibs/"
fi

echo ""
echo "📱 使用说明："
echo "1. 下载AAR到Android项目libs文件夹；"
echo "2. app/build.gradle添加：implementation files('libs/android-release.aar')；"
echo "3. 调用Letta-Lite核心功能（对话、记忆管理）。"
