#!/usr/bin/env bash
set -euo pipefail
set -x # 开启调试模式：输出每一条执行的命令，直接看到哪一步失败

echo "Building Letta Lite for Android (64-bit only)..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 核心配置（关键：改用官方最新稳定版 v4.1.2，和 GitHub 最新发布一致）
TARGET_ARCH="aarch64-linux-android"
RUST_TOOLCHAIN="nightly-2024-05-01"
FFI_MANIFEST_PATH="ffi/Cargo.toml"
ANDROID_API_LEVEL="24"
CARGO_NDK_TAG="v4.1.2" # 官方 GitHub 最新释放，100% 支持 --api 参数
OPENSSL_INSTALL_PATH="${OPENSSL_INSTALL_PATH:-/home/runner/work/letta-lite/letta-lite/openssl-install}"

# 检查必需工具（取消错误抑制，让缺失工具的报错直接显示）
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}" >&2 # 重定向到 stderr，确保日志捕获
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command git

# 检查NDK路径并验证版本（优化：NDK版本提取容错，避免空值报错）
check_ndk() {
    if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
        echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}" >&2
        exit 1
    fi
    export NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"
    
    # 优化：处理NDK路径不含rXX的情况（比如自定义命名）
    NDK_VERSION=$(basename "$NDK_HOME" | grep -oP 'r\K\d+' | head -1)
    if [ -z "$NDK_VERSION" ]; then
        echo -e "${YELLOW}Warning: Cannot extract NDK version from path, skip version check${NC}" >&2
    elif [ "$NDK_VERSION" -lt 25 ]; then
        echo -e "${RED}Error: Android NDK version must be ≥ r25 (current: r$NDK_VERSION)${NC}" >&2
        exit 1
    else
        echo -e "${GREEN}✅ NDK path valid (r$NDK_VERSION): $NDK_HOME${NC}"
    fi
}
check_ndk

# 安装指定版本cargo-ndk（取消错误抑制，让安装失败的详细日志显示）
echo "Uninstalling old cargo-ndk and installing official v$CARGO_NDK_TAG..."
cargo uninstall cargo-ndk || true # 去掉 2>/dev/null，让“未安装”提示显示（不影响执行）
if ! cargo install --git https://github.com/bbqsrc/cargo-ndk.git --tag "$CARGO_NDK_TAG" cargo-ndk --force; then
    echo -e "${RED}Error: Failed to install cargo-ndk v$CARGO_NDK_TAG${NC}" >&2
    echo -e "${YELLOW}Hint: Check if tag exists: https://github.com/bbqsrc/cargo-ndk/releases${NC}" >&2
    exit 1
fi

# 切换Rust工具链（简化：去掉非必要的rustfmt/clippy，减少干扰）
echo "Installing and switching to Rust toolchain: $RUST_TOOLCHAIN..."
rustup install "$RUST_TOOLCHAIN" || true
rustup default "$RUST_TOOLCHAIN"
rustup target add "$TARGET_ARCH" || true

# 设置RUSTFLAGS（保留核心，去掉非必要的lld链接器，减少兼容性问题）
echo "Setting RUSTFLAGS (OpenSSL path: $OPENSSL_INSTALL_PATH)..."
if [ ! -d "$OPENSSL_INSTALL_PATH/lib" ]; then
    echo -e "${RED}Error: OpenSSL library not found at $OPENSSL_INSTALL_PATH/lib${NC}" >&2
    exit 1
fi
export RUSTFLAGS="-L $OPENSSL_INSTALL_PATH/lib"

# 编译核心库（核心步骤：保留最小参数，避免多余配置干扰）
echo "Building Letta-Lite core library (arch: $TARGET_ARCH, API: $ANDROID_API_LEVEL)..."
cargo ndk \
    -t "$TARGET_ARCH" \
    --api "$ANDROID_API_LEVEL" \
    -o bindings/android/src/main/jniLibs \
    -- build \
        --manifest-path "$FFI_MANIFEST_PATH" \
        --profile mobile

# 生成C头文件（简化：去掉cbindgen自动生成，避免额外依赖干扰，只保留复制逻辑）
echo "Copying C header file (letta_lite.h)..."
if [ ! -f "ffi/include/letta_lite.h" ]; then
    echo -e "${RED}Error: letta_lite.h not found in ffi/include/${NC}" >&2
    exit 1
fi
cp ffi/include/letta_lite.h bindings/android/src/main/jni/

# 编译JNI wrapper（保留核心，去掉多余参数，确保基础编译）
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a
compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=$3
    echo "  Building JNI for $arch (API $api_level)..."
    CLANG_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/$triple$api_level-clang"
    
    if [ ! -f "$CLANG_PATH" ]; then
        echo -e "${RED}Error: Clang not found at $CLANG_PATH${NC}" >&2
        exit 1
    fi
    
    "$CLANG_PATH" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default-java}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default-java}/include/linux" \
        -I"$NDK_HOME/sysroot/usr/include" \
        -I"ffi/include" \
        -shared \
        -fPIC \
        -o "bindings/android/src/main/jniLibs/$arch/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/$arch" \
        -lletta_ffi \
        -llog \
        -ldl
}
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android" "$ANDROID_API_LEVEL"
else
    echo -e "${RED}Error: JNI source file (letta_jni.c) not found${NC}" >&2
    exit 1
fi

# 构建AAR（保留核心，去掉--no-daemon，简化命令）
echo "Building Android AAR (arm64-v8a)..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew clean assembleRelease
else
    echo -e "${RED}Error: gradlew not found in bindings/android${NC}" >&2
    exit 1
fi
cd ../..

# 验证构建结果
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ -f "$AAR_PATH" ]; then
    echo -e "\n${GREEN}✅ 64-bit Android AAR built successfully!${NC}"
    echo -e "📁 AAR Path: $AAR_PATH"
else
    echo -e "\n${RED}Error: AAR file not generated${NC}" >&2
    exit 1
fi
