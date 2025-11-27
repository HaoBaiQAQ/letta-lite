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

# 🔧 仅添加64位目标架构（arm64-v8a）
echo "Adding Android 64-bit target (aarch64-linux-android)..."
rustup target add aarch64-linux-android || true

# 🔧 仅编译64位，加--verbose便于排错（原作者核心编译逻辑不变）
echo "Building Letta FFI (64-bit)..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose  # 原作者的--profile mobile，正确

# 🔧 最终正确命令：生成C头文件（参数全对，无无效项）
echo "Generating C header (aarch64 architecture)..."
# 仅用3个有效参数：指定包、目标架构、编译配置，完全符合cargo build语法
cargo build -p letta-ffi --target=aarch64-linux-android --profile mobile
# 复制头文件到JNI目录（原作者逻辑，正确）
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || {
    echo -e "${YELLOW}Warning: 头文件未找到，尝试查找生成路径...${NC}"
    # 容错：如果头文件生成到target目录，自动复制
    HEAD_FILE=$(find ${{ github.workspace }}/target -name "letta_lite.h" -type f | head -n 1)
    if [ -n "$HEAD_FILE" ]; then
        cp "$HEAD_FILE" bindings/android/src/main/jni/
        echo -e "${GREEN}✅ 从$HEAD_FILE找到并复制头文件${NC}"
    else
        echo -e "${RED}❌ 头文件生成失败，终止编译${NC}"
        exit 1
    fi
}

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

# 原作者AAR构建逻辑（现在不会被打断，能正常执行）
echo "Building Android AAR..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    echo "Running gradlew assembleRelease..."
    ./gradlew assembleRelease --verbose --stacktrace
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ gradlew assembleRelease failed${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}gradlew not found, using system gradle${NC}"
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
