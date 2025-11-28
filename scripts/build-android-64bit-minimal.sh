#!/usr/bin/env bash
set -euo pipefail

# 从 Workflow 接收环境变量（保留必需）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_PATH=${NDK_PATH:-""}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}
export UNWIND_LIB_FILE=${UNWIND_LIB_FILE:-""}

# 强制链接器（核心保留）
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_TOOLCHAIN_BIN}/ld.lld"

# 颜色配置（保留）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查（保留）
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

# 核心验证（保留，只删无效路径）
if [ -z "${NDK_PATH}" ]; then
    echo -e "${RED}Error: 未获取到 NDK 根路径${NC}"
    exit 1
fi
if [ -z "${UNWIND_LIB_PATH}" ] || [ ! -f "${UNWIND_LIB_FILE}" ]; then
    echo -e "${RED}Error: 未获取到有效 libunwind 静态库路径${NC}"
    echo -e "  - UNWIND_LIB_PATH: ${UNWIND_LIB_PATH}"
    echo -e "  - UNWIND_LIB_FILE: ${UNWIND_LIB_FILE}"
    exit 1
fi
echo -e "${GREEN}✅ libunwind 静态库验证通过：${UNWIND_LIB_FILE}${NC}"

# 🔧 关键修改：动态查找所有系统库（包括 liblog.so），不硬编码旧路径
SYSTEM_LIB_PATH="${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL}"
# 动态查找 liblog.so（防止路径不一致）
LIBLOG_PATH=$(find "${NDK_SYSROOT}" -name "liblog.so" | grep -E "${TARGET}|arm64" | head -n 1)
if [ -z "${LIBLOG_PATH}" ]; then
    LIBLOG_PATH=$(find "${NDK_PATH}" -name "liblog.so" | grep -E "android-${ANDROID_API_LEVEL}|arm64" | head -n 1)
fi
[ -z "${LIBLOG_PATH}" ] && { echo -e "${RED}Error: 找不到 liblog.so，请检查 NDK 安装${NC}"; exit 1; }
# 提取 liblog.so 所在目录，添加到库路径
LIBLOG_DIR=$(dirname "${LIBLOG_PATH}")

# 验证其他系统库（libdl.so/libm.so/libc.so）
REQUIRED_LIBS=(
    "${SYSTEM_LIB_PATH}/libdl.so"
    "${SYSTEM_LIB_PATH}/libm.so"
    "${SYSTEM_LIB_PATH}/libc.so"
)
for lib in "${REQUIRED_LIBS[@]}"; do
    if [ ! -f "${lib}" ]; then
        echo -e "${RED}Error: 找不到库文件：${lib}${NC}"
        echo -e "  尝试动态查找...";
        DYNAMIC_LIB=$(find "${NDK_SYSROOT}" -name "$(basename "${lib}")" | grep -E "${TARGET}" | head -n 1)
        [ -z "${DYNAMIC_LIB}" ] && { echo -e "${RED}动态查找也失败${NC}"; exit 1; }
        echo -e "  动态找到：${DYNAMIC_LIB}${NC}";
        # 更新路径为动态找到的目录
        SYSTEM_LIB_PATH=$(dirname "${DYNAMIC_LIB}")
    fi
done
echo -e "${GREEN}✅ 所有系统库验证通过：${NC}"
echo -e "  - 系统库目录：${SYSTEM_LIB_PATH}"
echo -e "  - liblog.so 目录：${LIBLOG_DIR}"

# 其他必需参数验证（保留）
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: 必需环境变量未传递${NC}"
    exit 1
fi

# OpenSSL 路径配置（保留）
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
echo -e "${GREEN}✅ OPENSSL 路径配置完成：${NC}"
echo -e "  - OPENSSL_LIB_DIR: ${OPENSSL_LIB_DIR}"
echo -e "  - OPENSSL_INCLUDE_DIR: ${OPENSSL_INCLUDE_DIR}"

# 确保 Cargo 配置生效（保留）
export CARGO_ENCODED_RUSTFLAGS=""
echo "Building Letta Lite for Android (${TARGET}) - 适配 NDK 27 无旧路径版"
echo -e "${GREEN}✅ 核心依赖路径验证通过：${NC}"
echo -e "  - NDK 根路径：${NDK_PATH}"
echo -e "  - 链接器：${CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER}"
echo -e "  - UNWIND_LIB_PATH: ${UNWIND_LIB_PATH}"

# 安装目标平台标准库（保留）
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}" 2>/dev/null || true
echo -e "${GREEN}✅ 目标平台安装完成${NC}"

# 🔧 RUSTFLAGS 只保留有效路径（无任何旧路径）
export RUSTFLAGS="\
--sysroot=${NDK_SYSROOT} \
-L ${SYSTEM_LIB_PATH} \
-L ${LIBLOG_DIR} \
-L ${UNWIND_LIB_PATH} \
-L ${OPENSSL_LIB_DIR} \
-l:libunwind.a \
-l:libdl.so \
-l:liblog.so \
-l:libm.so \
-l:libc.so \
-C linker=${NDK_TOOLCHAIN_BIN}/ld.lld \
-C link-arg=-fuse-ld=lld \
-C link-arg=--allow-shlib-undefined"

# 交叉编译依赖配置（保留）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译核心库（保留）
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo ndk -t arm64-v8a -o "${PWD}/bindings/android/src/main/jniLibs" build --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成头文件（保留）
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build --target="${TARGET}" --profile mobile --verbose -p letta-ffi
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
    [ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
fi
mkdir -p ffi/include && cp "${HEADER_FILE}" ffi/include/
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 验证静态链接（保留）
echo -e "\n${YELLOW}=== 验证静态链接 ===${NC}"
if readelf -d "${CORE_SO}" | grep -q "unwind"; then
    echo -e "${YELLOW}⚠️  警告：libunwind 可能被动态链接${NC}"
else
    echo -e "${GREEN}✅ libunwind 静态链接验证通过${NC}"
fi

# 编译 JNI 库（保留）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"ffi/include" \
    -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" -lletta_ffi -L"${OPENSSL_LIB_DIR}" \
    -ldl -llog -lssl -lcrypto -O2
[ ! -f "${JNI_DIR}/libletta_jni.so" ] && { echo -e "${RED}Error: JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功${NC}"

# 打包 AAR（保留）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android
./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
cd ../..
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
[ ! -f "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR 打包失败${NC}"; exit 1; }
echo -e "${GREEN}✅ AAR 打包成功${NC}"

# 收集产物（保留）
mkdir -p "${PWD}/release"
cp "${CORE_SO}" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "${AAR_PATH}" "${PWD}/release/"
cp "${HEADER_FILE}" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27${NC}"
echo -e "${GREEN}📦 产物：release/ 目录下（.so + .aar + 头文件）${NC}"
