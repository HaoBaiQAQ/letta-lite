#!/usr/bin/env bash
set -euo pipefail

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
export NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 🔧 微改1：仅添加64位目标架构（arm64-v8a）
echo "Adding Android 64-bit target..."
rustup target add aarch64-linux-android || true

# 🔧 微改2：仅编译64位，加--verbose便于排错（原作者核心编译逻辑不变）
echo "Building Letta FFI (64-bit)..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose  # 仅加--verbose

# 原作者头文件生成逻辑
echo "Generating C header..."
cargo build -p letta-ffi --features cbindgen
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || true

# 🔧 微改3：仅编译64位JNI（原作者编译逻辑不变）
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
        -Iffi/include \
        -shared \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi
}

if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"  # 仅保留64位
else
    echo -e "${YELLOW}Warning: JNI wrapper not found, skipping JNI compilation${NC}"
    exit 1  # JNI缺失会导致AAR无用，直接报错
fi

# 原作者AAR构建逻辑
echo "Building Android AAR..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --verbose  # 加--verbose排错
else
    gradle assembleRelease --verbose
fi
cd ../..

# 🔧 新增：验证产物（避免无声失败）
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
SO_PATH="bindings/android/src/main/jniLibs/arm64-v8a/libletta_jni.so"
if [ -f "$AAR_PATH" ] && [ -f "$SO_PATH" ]; then
    echo -e "${GREEN}✅ Build successful!${NC}"
    echo "AAR: $AAR_PATH"
    echo "SO: $SO_PATH"
else
    echo -e "${RED}❌ Build failed: 产物缺失${NC}"
    exit 1
fi
