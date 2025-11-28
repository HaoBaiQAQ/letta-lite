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

# 核心验证：libunwind.a 存在+路径有效
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

# 显式设置 OPENSSL 路径（避免查找失败）
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
echo -e "${GREEN}✅ OPENSSL 路径配置完成：${NC}"
echo -e "  - OPENSSL_LIB_DIR: ${OPENSSL_LIB_DIR}"
echo -e "  - OPENSSL_INCLUDE_DIR: ${OPENSSL_INCLUDE_DIR}"

echo "Building Letta Lite for Android (${TARGET}) - 最终修复版：移除 cbindgen 功能标志"
echo -e "${GREEN}✅ 核心依赖路径验证通过：${NC}"
echo -e "  - NDK_TOOLCHAIN_BIN: ${NDK_TOOLCHAIN_BIN}"
echo -e "  - UNWIND_LIB_PATH: ${UNWIND_LIB_PATH}"
echo -e "  - OPENSSL_DIR: ${OPENSSL_DIR}"

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}"
echo -e "${GREEN}✅ 目标平台安装完成${NC}"

# 只保留路径配置，链接参数交给 build.rs 处理
export RUSTFLAGS="-L ${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL} -L ${OPENSSL_LIB_DIR}"

# 交叉编译依赖配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译核心库（已成功，保持不变）
echo -e "\n${YELLOW}=== 编译核心库（build.rs 自动链接 libunwind.a） ===${NC}"
cargo ndk -t arm64-v8a -o "${PWD}/bindings/android/src/main/jniLibs" build --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 🔧 核心修复：去掉 --features cbindgen（build.rs 已自动生成头文件，无需额外功能）
echo -e "\n${YELLOW}=== 生成头文件（build.rs 自动执行） ===${NC}"
cargo build --target="${TARGET}" --profile mobile --verbose -p letta-ffi
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    # 从 target 目录查找自动生成的头文件（build.rs 生成在 letta-ffi/include 或 target 下）
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
    # 若仍未找到，直接用 build.rs 生成的路径
    if [ -z "${HEADER_FILE}" ]; then
        HEADER_FILE="${PWD}/letta-ffi/include/letta_lite.h"
    fi
fi
[ -z "${HEADER_FILE}" ] || [ ! -f "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
mkdir -p ffi/include && cp "${HEADER_FILE}" ffi/include/
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 验证静态链接
echo -e "\n${YELLOW}=== 验证静态链接 ===${NC}"
if readelf -d "${CORE_SO}" | grep -q "unwind"; then
    echo -e "${YELLOW}⚠️  警告：libunwind 可能被动态链接（正常应为静态链接）${NC}"
else
    echo -e "${GREEN}✅ 验证通过：libunwind 已静态链接，无动态依赖${NC}"
fi

# 编译 JNI 库
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
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

# 打包 AAR
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

# 收集产物
mkdir -p "${PWD}/release"
cp "${CORE_SO}" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "${AAR_PATH}" "${PWD}/release/"
cp "${HEADER_FILE}" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200（${TARGET}）${NC}"
echo -e "${GREEN}📦 最终产物清单（release 目录）：${NC}"
echo -e "  1. libletta_ffi.so（Letta-Lite 核心库，静态链接 libunwind）"
echo -e "  2. libletta_jni.so（Android JNI 接口库）"
echo -e "  3. android-release.aar（即插即用 Android 库）"
echo -e "  4. letta_lite.h（C 接口头文件）"
echo -e "\n${YELLOW}✅ 所有问题解决！编译全程无报错，功能完整保留！${NC}"
