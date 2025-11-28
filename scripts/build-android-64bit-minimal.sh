#!/usr/bin/env bash
set -euo pipefail

# 🔧 强制仅编译64位架构，继承工作流环境变量
export CARGO_TARGET=aarch64-linux-android
export ANDROID_ABI=arm64-v8a
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}

echo "Building Letta Lite for Android (64-bit only) - 终极手动编译版..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command rustc

# 🔧 1. 验证 NDK 配置（不变）
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ]; then
    echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 或 NDK_SYSROOT 未传递${NC}"
    exit 1
fi

# 🔧 2. 清理污染的环境变量（不变）
unset CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER 2>/dev/null
echo -e "${GREEN}✅ 清理污染的环境变量完成${NC}"

# 🔧 3. 配置交叉编译器（不变）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${CARGO_TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
if [ ! -f "${CC_aarch64_linux_android}" ]; then
    echo -e "${RED}Error: 交叉编译器不存在：${CC_aarch64_linux_android}${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 交叉编译器配置完成${NC}"

# 🔧 4. 配置 OpenSSL（不变）
if [ -z "${OPENSSL_DIR:-}" ]; then
    echo -e "${RED}Error: OPENSSL_DIR 未传递${NC}"
    exit 1
fi
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export PKG_CONFIG_ALLOW_CROSS=1
echo -e "${GREEN}✅ OpenSSL 配置完成${NC}"

# 🔧 5. 安装 cargo-ndk（不变）
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk --version=3.5.4 --locked
fi

# 🔧 6. 检查 NDK 环境变量（不变）
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME 未设置${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-${ANDROID_NDK_HOME:-}}"

# 🔧 步骤1：编译核心库（已成功）
echo "Building Letta FFI core library..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose
echo -e "${GREEN}✅ 核心库 libletta_ffi.so 生成成功！${NC}"

# 🔧 步骤2：手动调用 rustc 触发 build.rs 生成头文件（终极修复！）
echo "Generating C header (手动调用 rustc，规避 cargo 参数坑)..."
# 核心逻辑：直接用 rustc 编译 build.rs，触发头文件生成，不通过 cargo
BUILD_SCRIPT="ffi/build.rs"
if [ ! -f "${BUILD_SCRIPT}" ]; then
    echo -e "${RED}Error: build.rs 未找到${NC}"
    exit 1
fi

# 手动设置 build.rs 编译的环境变量（和 cargo 自动传递的一致）
export OUT_DIR="${GITHUB_WORKSPACE}/target/aarch64-linux-android/mobile/build/letta-ffi-59a76ea2a7951a8d/out"
export CARGO_MANIFEST_DIR="${GITHUB_WORKSPACE}/ffi"
export CARGO_PKG_NAME="letta-ffi"
export CARGO_PKG_VERSION="0.1.0"
export CC="${CC_aarch64_linux_android}"

# 手动编译 build.rs 并执行（触发 cbindgen 生成头文件）
rustc \
    --edition=2018 \
    --target="${CARGO_TARGET}" \
    --sysroot="${NDK_SYSROOT}" \
    -L "${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API_LEVEL}" \
    -o "${OUT_DIR}/build-script-build" \
    "${BUILD_SCRIPT}" \
    --cfg procmacro2_semver_exempt \
    --cfg rustix_use_libc \
    -ldl -llog -lm -lc -lunwind
"${OUT_DIR}/build-script-build"

# 验证头文件
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    echo -e "${YELLOW}Searching for header file...${NC}"
    HEADER_FILE=$(find "${GITHUB_WORKSPACE}" -name "letta_lite.h" | grep -v "target/debug" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件未找到${NC}"
        exit 1
    fi
fi
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件已复制到 JNI 目录：${HEADER_FILE}${NC}"

# 🔧 步骤3：编译 JNI（不变）
echo "Compiling JNI wrapper..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=21
    
    echo "  Building JNI for ${arch}..."
    "${NDK_HOME}"/toolchains/llvm/prebuilt/*/bin/clang \
        --target="${triple}${api_level}" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"${NDK_HOME}/sysroot/usr/include" \
        -Ibindings/android/src/main/jni/ \
        -shared \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi
}

if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
    echo -e "${GREEN}✅ JNI 库 libletta_jni.so 生成成功！${NC}"
else
    echo -e "${RED}Error: JNI 源码未找到${NC}"
    exit 1
fi

# 🔧 步骤4：打包 AAR（不变）
echo "Building Android AAR..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --verbose --stacktrace
else
    gradle assembleRelease --verbose --stacktrace
fi
cd ../..

# 🔧 验证产物
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
SO_PATH="bindings/android/src/main/jniLibs/arm64-v8a/libletta_jni.so"
if [ -f "$AAR_PATH" ] && [ -f "$SO_PATH" ]; then
    echo -e "${GREEN}🎉 所有产物生成成功！适配天玑1200（aarch64）${NC}"
    echo "📦 AAR: ${AAR_PATH}"
    echo "📦 JNI SO: ${SO_PATH}"
else
    echo -e "${RED}❌ 产物生成失败${NC}"
    exit 1
fi
