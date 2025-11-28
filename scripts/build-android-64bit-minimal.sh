#!/usr/bin/env bash
set -euo pipefail

# 🔧 核心配置（参考 Tauri 交叉编译规范）
export TARGET=aarch64-linux-android
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}
# 关键：通过环境变量指定 linker（绕开 -- -C 参数传递 bug）
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_TOOLCHAIN_BIN}/ld.lld"

echo "Building Letta Lite for Android (${TARGET}) - 开源项目通用方案版..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查（参考 Flutter Rust Bridge 依赖规范）
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: 缺失必要工具 $1（参考开源项目依赖要求）${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command rustc
check_command cbindgen
check_command clang
check_command cargo-ndk

# 🔧 1. 验证核心配置（避免空值导致的路径错误）
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: NDK_TOOLCHAIN_BIN/NDK_SYSROOT/OPENSSL_DIR 必须传递${NC}"
    exit 1
fi

# 🔧 2. 确保目标平台 Rust 标准库已安装（核心修复！）
echo -e "${YELLOW}=== 验证 Rust 标准库（避免 core/std 缺失）===${NC}"
if ! rustup target list | grep -q "${TARGET} (installed)"; then
    echo -e "${YELLOW}正在安装 ${TARGET} 标准库...${NC}"
    rustup target add "${TARGET}" || {
        echo -e "${RED}Error: 标准库安装失败（可能需要更新 Rust 工具链）${NC}"
        exit 1
    }
fi
# 验证标准库路径存在
RUST_STDLIB_PATH=$(rustc --print sysroot)/lib/rustlib/${TARGET}/lib
if [ ! -d "${RUST_STDLIB_PATH}" ] || [ ! -f "${RUST_STDLIB_PATH}/libcore.rlib" ]; then
    echo -e "${RED}Error: 未找到 ${TARGET} 标准库（路径：${RUST_STDLIB_PATH}）${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Rust 标准库验证完成（路径：${RUST_STDLIB_PATH}）${NC}"

# 🔧 3. 配置交叉编译依赖（仅给 C/C++ 编译器用，不影响 Rust）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export PKG_CONFIG_ALLOW_CROSS=1

# 验证交叉编译器和 OpenSSL
if [ ! -f "${CC_aarch64_linux_android}" ]; then
    echo -e "${RED}Error: 交叉编译器 ${CC_aarch64_linux_android} 不存在${NC}"
    exit 1
fi
if [ ! -d "${OPENSSL_INCLUDE_DIR}" ] || [ ! -f "${OPENSSL_LIB_DIR}/libssl.so" ]; then
    echo -e "${RED}Error: OpenSSL 路径无效（未找到 libssl.so）${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 交叉编译环境配置完成${NC}"

# 🔧 4. 编译核心库（参考 cargo-ndk 官方示例）
echo -e "\n${YELLOW}=== 编译核心库（${TARGET}）===${NC}"
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose
CORE_SO="bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
if [ ! -f "${CORE_SO}" ]; then
    echo -e "${RED}Error: 核心库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 核心库 ${CORE_SO} 生成成功${NC}"

# 🔧 5. 生成头文件（参考 cbindgen 官方自动生成方案）
echo -e "\n${YELLOW}=== 生成头文件（自动触发 build.rs）===${NC}"
# 关键：不传递任何 Rustc 参数，让 Cargo 自动处理
cargo build -p letta-ffi \
    --target="${TARGET}" \
    --verbose \
    --profile mobile

# 查找并验证头文件
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    HEADER_FILE=$(find "${PWD}/target/${TARGET}/mobile/build" -name "letta_lite.h" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件生成失败（检查 build.rs 是否正确调用 cbindgen）${NC}"
        exit 1
    fi
    mkdir -p ffi/include
    cp "${HEADER_FILE}" "ffi/include/"
fi
cp "${HEADER_FILE}" "bindings/android/src/main/jni/"
echo -e "${GREEN}✅ 头文件 ${HEADER_FILE} 生成完成${NC}"

# 🔧 6. 编译 JNI 库（参考 Android NDK 官方编译规范）
echo -e "\n${YELLOW}=== 编译 JNI 库（仅此处使用 NDK sysroot）===${NC}"
JNI_DIR="bindings/android/src/main/jniLibs/arm64-v8a"
mkdir -p "${JNI_DIR}"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \  # 仅 JNI 编译用 NDK sysroot
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"bindings/android/src/main/jni/" \
    -I"${OPENSSL_INCLUDE_DIR}" \
    -shared \
    -fPIC \
    -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" \
    -lletta_ffi \
    -L"${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL}" \
    -L"${OPENSSL_LIB_DIR}" \
    -ldl -llog -lm -lc -lunwind -lssl -lcrypto \
    -O2
if [ ! -f "${JNI_DIR}/libletta_jni.so" ]; then
    echo -e "${RED}Error: JNI 库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ JNI 库 ${JNI_DIR}/libletta_jni.so 生成成功${NC}"

# 🔧 7. 打包 AAR（参考 Flutter Rust Bridge AAR 打包方案）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android
chmod +x gradlew
./gradlew assembleRelease --no-daemon --verbose --stacktrace \
    -Dorg.gradle.jvmargs="-Xmx2g" \
    -Pandroid.ndkVersion="${ANDROID_NDK_VERSION}" \
    -Pandroid.minSdkVersion="${ANDROID_API_LEVEL}"
cd ../..

# 🔧 8. 验证最终产物
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ ! -f "${AAR_PATH}" ]; then
    echo -e "${RED}Error: AAR 打包失败${NC}"
    exit 1
fi

# 收集产物
mkdir -p ./release
cp "${CORE_SO}" ./release/
cp "${JNI_DIR}/libletta_jni.so" ./release/
cp "${AAR_PATH}" ./release/
cp "${HEADER_FILE}" ./release/

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200（${TARGET}）${NC}"
echo -e "${GREEN}📦 产物列表：${NC}"
echo -e "  - 核心库：release/libletta_ffi.so"
echo -e "  - JNI 库：release/libletta_jni.so"
echo -e "  - AAR 包：release/android-release.aar"
echo -e "  - 头文件：release/letta_lite.h"
echo -e "\n${YELLOW}✅ 方案参考：Helix 编辑器 + Flutter Rust Bridge + Tauri 交叉编译规范${NC}"
