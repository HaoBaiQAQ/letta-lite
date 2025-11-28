#!/usr/bin/env bash
set -euo pipefail

# 🔧 强制仅编译64位架构，继承工作流环境变量
export CARGO_TARGET=aarch64-linux-android
export ANDROID_ABI=arm64-v8a
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}

echo "Building Letta Lite for Android (64-bit only) - 根源修复版（不绕路）..."

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

# 🔧 1. 验证 NDK 配置（不变）
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ]; then
    echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 或 NDK_SYSROOT 未传递${NC}"
    exit 1
fi

# 🔧 2. 清理可能被 cargo ndk 污染的环境变量（核心！）
# 移除之前设置的链接器配置，避免和手动传递的 -C linker 冲突
unset CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER 2>/dev/null
echo -e "${GREEN}✅ 清理污染的环境变量完成${NC}"

# 🔧 3. 配置交叉编译器（仅给 openssl-sys 用，不影响 linker）
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

# 🔧 步骤1：编译核心库（用 cargo ndk，已成功）
echo "Building Letta FFI core library..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose
echo -e "${GREEN}✅ 核心库 libletta_ffi.so 生成成功！${NC}"

# 🔧 步骤2：生成头文件（根源修复！极简参数传递，不绕路）
echo "Generating C header (根源修复参数传递)..."
# 核心修改：
# 1. 清理 RUSTFLAGS，只保留必要的 sysroot 和库路径（无多余参数）
# 2. cargo build 命令用单行写，-- 后面紧跟 -C linker，避免 shell 解析错误
# 3. 不继承任何污染的环境变量，完全干净的参数传递
export RUSTFLAGS="--sysroot=${NDK_SYSROOT} -L ${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API_LEVEL} -ldl -llog -lm -lc -lunwind"
cargo build -p letta-ffi --target="${CARGO_TARGET}" --verbose -- -C linker="${NDK_TOOLCHAIN_BIN}/ld.lld"

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
