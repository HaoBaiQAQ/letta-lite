#!/usr/bin/env bash
set -euo pipefail

# 从 Workflow 接收环境变量
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}
export UNWIND_LIB_FILE=${UNWIND_LIB_FILE:-""}
export OPENSSL_LIB_DIR=${OPENSSL_LIB_DIR:-""}

# 绕开 -- -C 参数传递 bug（开源项目通用方案）
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_TOOLCHAIN_BIN}/ld.lld"

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: 缺失工具 $1${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command cargo-ndk
check_command clang

# 核心验证：静态库 libunwind.a 存在
if [ -z "${UNWIND_LIB_PATH}" ] || [ ! -f "${UNWIND_LIB_FILE}" ]; then
    echo -e "${RED}Error: 未获取到有效 libunwind 静态库路径${NC}"
    echo -e "  - UNWIND_LIB_PATH: ${UNWIND_LIB_PATH}"
    echo -e "  - UNWIND_LIB_FILE: ${UNWIND_LIB_FILE}"
    exit 1
fi
echo -e "${GREEN}✅ libunwind 静态库验证通过：${UNWIND_LIB_FILE}${NC}"

# 其他必需参数验证
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: 必需环境变量未传递${NC}"
    exit 1
fi

echo "Building Letta Lite for Android (${TARGET}) - 最终规范版：修正静态库链接语法"
echo -e "${GREEN}✅ 核心依赖路径验证通过：${NC}"
echo -e "  - NDK_TOOLCHAIN_BIN: ${NDK_TOOLCHAIN_BIN}"
echo -e "  - OPENSSL_DIR: ${OPENSSL_DIR}"
echo -e "  - UNWIND_LIB_PATH: ${UNWIND_LIB_PATH}"

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}"
echo -e "${GREEN}✅ 目标平台安装完成${NC}"

# RUSTFLAGS 只保留路径（正确配置）
export RUSTFLAGS="-L ${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL} -L ${UNWIND_LIB_PATH} -L ${OPENSSL_LIB_DIR}"

# 交叉编译依赖配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export PKG_CONFIG_ALLOW_CROSS=1

# 🔧 核心修正：把 -l:libunwind.a 改成 -lstatic=unwind（Rustc 规范静态库语法）
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo ndk -t arm64-v8a -o bindings/android/src/main/jniLibs build --profile mobile --verbose -p letta-ffi -- -lstatic=unwind
CORE_SO="bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 🔧 同样修正头文件生成命令
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build --target="${TARGET}" --profile mobile --features cbindgen --verbose -p letta-ffi -- -lstatic=unwind
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
fi
[ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
mkdir -p ffi/include && cp "${HEADER_FILE}" ffi/include/
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 编译 JNI 库（完全保留原作者逻辑）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="bindings/android/src/main/jniLibs/arm64-v8a"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"${NDK_SYSROOT}/usr/include" \
    -I"ffi/include" \
    -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" -lletta_ffi -L"${OPENSSL_LIB_DIR}" \
    -ldl -llog -lssl -lcrypto -O2
[ ! -f "${JNI_DIR}/libletta_jni.so" ] && { echo -e "${RED}Error: JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功：${JNI_DIR}/libletta_jni.so${NC}"

# 打包 AAR（保留原作者逻辑）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android
if [ -f "gradlew" ]; then
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
else
    gradle assembleRelease
fi
cd ../..
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
[ ! -f "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR 打包失败${NC}"; exit 1; }
echo -e "${GREEN}✅ AAR 打包成功：${AAR_PATH}${NC}"

# 收集产物（统一输出到 release 目录）
mkdir -p ./release
cp "${CORE_SO}" ./release/
cp "${JNI_DIR}/libletta_jni.so" ./release/
cp "${AAR_PATH}" ./release/
cp "${HEADER_FILE}" ./release/

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200（${TARGET}）${NC}"
echo -e "${GREEN}📦 最终产物清单（release 目录）：${NC}"
echo -e "  1. libletta_ffi.so（Letta-Lite 核心库）"
echo -e "  2. libletta_jni.so（Android JNI 接口库）"
echo -e "  3. android-release.aar（即插即用 Android 库）"
echo -e "  4. letta_lite.h（C 接口头文件）"
echo -e "\n${YELLOW}✅ 规范链接语法！保留栈展开功能，Rustc 能正确识别静态库！${NC}"
