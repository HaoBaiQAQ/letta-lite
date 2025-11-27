#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 核心配置（关键修复：cargo-ndk v0.10.0 标签不存在，替换为官方已发布的稳定版 v0.11.0）
TARGET_ARCH="aarch64-linux-android"
RUST_TOOLCHAIN="nightly-2024-05-01" # 固定nightly版本，避免兼容性波动
FFI_MANIFEST_PATH="ffi/Cargo.toml"
ANDROID_API_LEVEL="24"
CARGO_NDK_TAG="v0.11.0" # 官方存在的稳定版标签（支持 --api 参数，适配NDK r25+）
OPENSSL_INSTALL_PATH="${OPENSSL_INSTALL_PATH:-/home/runner/work/letta-lite/letta-lite/openssl-install}" # 可通过环境变量覆盖，避免硬编码

# 检查必需工具
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command git

# 检查NDK路径并验证版本（新增：确保NDK ≥ r25，避免兼容性问题）
check_ndk() {
    if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
        echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
        exit 1
    fi
    export NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"
    
    # 提取NDK版本（r25c → 25，r26 → 26）
    NDK_VERSION=$(basename "$NDK_HOME" | grep -oP 'r\K\d+' | head -1)
    if [ -z "$NDK_VERSION" ] || [ "$NDK_VERSION" -lt 25 ]; then
        echo -e "${RED}Error: Android NDK version must be ≥ r25 (current: r$NDK_VERSION)${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ NDK path valid (r$NDK_VERSION): $NDK_HOME${NC}"
}
check_ndk

# 安装指定版本cargo-ndk（修复：使用存在的标签v0.11.0）
echo "Uninstalling old cargo-ndk and installing official v$CARGO_NDK_TAG..."
cargo uninstall cargo-ndk 2>/dev/null || true
if ! cargo install --git https://github.com/bbqsrc/cargo-ndk.git --tag "$CARGO_NDK_TAG" cargo-ndk --force; then
    echo -e "${RED}Error: Failed to install cargo-ndk v$CARGO_NDK_TAG${NC}"
    echo -e "${YELLOW}Hint: Check tags at https://github.com/bbqsrc/cargo-ndk/tags${NC}"
    exit 1
fi

# 切换到固定版本的Nightly工具链（避免自动更新导致的编译失败）
echo "Installing and switching to Rust toolchain: $RUST_TOOLCHAIN..."
rustup install "$RUST_TOOLCHAIN" || true
rustup default "$RUST_TOOLCHAIN"
rustup component add rustfmt clippy --toolchain "$RUST_TOOLCHAIN" # 新增：添加开发工具组件

# 添加目标架构
echo "Adding 64-bit Android target ($TARGET_ARCH)..."
rustup target add "$TARGET_ARCH" || true

# 设置RUSTFLAGS（优化：OpenSSL路径从环境变量读取，适配不同环境）
echo "Setting RUSTFLAGS (OpenSSL path: $OPENSSL_INSTALL_PATH)..."
if [ ! -d "$OPENSSL_INSTALL_PATH/lib" ]; then
    echo -e "${RED}Error: OpenSSL library not found at $OPENSSL_INSTALL_PATH/lib${NC}"
    exit 1
fi
export RUSTFLAGS="-L $OPENSSL_INSTALL_PATH/lib -C link-arg=-fuse-ld=lld" # 新增：使用lld链接器，加速编译

# 编译核心库（合并重复编译步骤，优化效率）
echo "Building Letta-Lite core library (arch: $TARGET_ARCH, API: $ANDROID_API_LEVEL)..."
cargo ndk \
    -t "$TARGET_ARCH" \
    --api "$ANDROID_API_LEVEL" \
    -o bindings/android/src/main/jniLibs \
    -- build \
        --manifest-path "$FFI_MANIFEST_PATH" \
        --profile mobile

# 生成C头文件（复用之前的编译结果，无需重复构建）
echo "Generating C header file (letta_lite.h)..."
if [ ! -f "ffi/include/letta_lite.h" ]; then
    echo -e "${YELLOW}Warning: letta_lite.h not found in ffi/include/，trying to generate...${NC}"
    # 若头文件未提前生成，尝试通过cbindgen生成（新增：增强容错性）
    if command -v cbindgen &> /dev/null; then
        cbindgen --config ffi/cbindgen.toml --output ffi/include/letta_lite.h ffi/src/
    else
        echo -e "${RED}Error: cbindgen not installed, cannot generate letta_lite.h${NC}"
        exit 1
    fi
fi
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || {
    echo -e "${RED}Error: Failed to copy letta_lite.h${NC}"
    exit 1
}

# 编译JNI wrapper（修复：添加libunwind路径，适配部分NDK版本）
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a
compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=$3
    echo "  Building JNI for $arch (API $api_level)..."
    CLANG_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/$triple$api_level-clang"
    UNWIND_PATH="$NDK_HOME/sysroot/usr/lib/$triple$api_level" # 新增：指定libunwind路径
    
    if [ ! -f "$CLANG_PATH" ]; then
        echo -e "${RED}Error: Clang not found at $CLANG_PATH${NC}"
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
        -L"$UNWIND_PATH" \ # 链接libunwind
        -lletta_ffi \
        -llog \
        -lunwind \
        -ldl
}
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android" "$ANDROID_API_LEVEL"
else
    echo -e "${RED}Error: JNI source file (letta_jni.c) not found${NC}"
    exit 1
fi

# 构建AAR（优化：优先使用项目自带gradlew，避免版本冲突）
echo "Building Android AAR (arm64-v8a)..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew clean assembleRelease --no-daemon # 新增：clean+--no-daemon，避免缓存问题
else
    echo -e "${RED}Error: gradlew not found in bindings/android${NC}"
    exit 1
fi
cd ../..

# 验证构建结果
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ -f "$AAR_PATH" ]; then
    echo -e "\n${GREEN}✅ 64-bit Android AAR built successfully!${NC}"
    echo -e "📁 AAR Path: $AAR_PATH"
else
    echo -e "\n${RED}Error: AAR file not generated${NC}"
    exit 1
fi

echo -e "\n📱 Usage Guide:"
echo "1. Copy the AAR file to your Android project's 'app/libs' folder;"
echo "2. Add to app/build.gradle:"
echo "   dependencies {"
echo "       implementation files('libs/android-release.aar')"
echo "   }"
echo "3. Ensure your app's minSdkVersion ≥ $ANDROID_API_LEVEL;"
echo "4. Call Letta-Lite core functions via JNI wrapper."
