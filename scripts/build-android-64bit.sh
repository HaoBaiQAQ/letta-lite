#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit arm64-v8a only)..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 仅保留作者脚本的核心工具检查（rustup、cargo）
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

check_command rustup
check_command cargo

# 安装cargo-ndk（保留作者的crates.io安装，删除GitHub特定版本，避免冲突）
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# 检查NDK路径（保留作者逻辑）
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 仅添加64位目标架构（保留你们的需求）
echo "Adding Android 64-bit target (aarch64-linux-android)..."
rustup target add aarch64-linux-android || true

# 核心编译（参考作者逻辑，简化参数，仅64位）
echo "Building for Android 64-bit (arm64-v8a)..."
cargo ndk \
    -t aarch64-linux-android \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile

# 生成头文件（保留作者逻辑，容错处理）
echo "Generating C header..."
if [ -f "ffi/include/letta_lite.h" ]; then
    cp ffi/include/letta_lite.h bindings/android/src/main/jni/
else
    echo -e "${YELLOW}letta_lite.h 未找到，用cbindgen直接生成...${NC}"
    cargo install cbindgen || true
    cbindgen --config ffi/cbindgen.toml --output bindings/android/src/main/jni/letta_lite.h ffi/src/
fi

# 编译64位JNI（参考作者逻辑，简化路径查找）
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=21
    
    echo "  Building JNI for $arch (API $api_level)..."
    # 参考作者脚本，用通配符匹配prebuilt目录，避免find失败
    CLANG_PATH="${NDK_HOME}/toolchains/llvm/prebuilt/*/bin/clang"
    
    local JAVA_INCLUDE="${JAVA_HOME:-/usr/lib/jvm/default-java}/include"
    [ ! -d "$JAVA_INCLUDE" ] && JAVA_INCLUDE="/usr/lib/jvm/java-11-openjdk-amd64/include"

    "$CLANG_PATH" \
        --target="${triple}${api_level}" \
        -I"$JAVA_INCLUDE" \
        -I"$JAVA_INCLUDE/linux" \
        -I"${NDK_HOME}/sysroot/usr/include" \
        -I"bindings/android/src/main/jni" \
        -shared -fPIC \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi \
        -llog \
        -ldl
}

# 仅编译arm64-v8a的JNI
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
else
    echo -e "${YELLOW}Warning: JNI wrapper not found, skipping JNI compilation${NC}"
fi

# 构建AAR（保留作者逻辑）
if command -v gradle &> /dev/null || [ -f "bindings/android/gradlew" ]; then
    echo "Building Android AAR..."
    cd bindings/android
    if [ -f "gradlew" ]; then
        chmod +x gradlew
        ./gradlew clean assembleRelease --no-daemon
    else
        gradle assembleRelease
    fi
    cd ../..
    
    # 验证产物
    AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
    if [ -f "$AAR_PATH" ]; then
        echo -e "\n${GREEN}✅ Android 64-bit (arm64-v8a) build successful!${NC}"
        echo -e "📁 AAR Location: $AAR_PATH"
    else
        echo -e "\n${RED}❌ Error: AAR file not generated${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}Android libraries built!${NC}"
    echo -e "📁 Libraries location: bindings/android/src/main/jniLibs/"
fi

# 用法说明（保留你们的逻辑）
echo -e "\n📋 Usage Instructions:"
echo "1. Copy the AAR file to your Android project's 'app/libs' folder"
echo "2. Add to app/build.gradle:"
echo "   dependencies {"
echo "       implementation files('libs/android-release.aar')"
echo "   }"
echo "3. Ensure minSdkVersion ≥ 21"
echo "4. Import in Kotlin: import ai.letta.lite.LettaLite"
