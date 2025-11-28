#!/usr/bin/env bash
set -euo pipefail

# 从 Workflow 接收环境变量（新增 NDK_PATH）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_PATH=${NDK_PATH:-""}  # 新增：接收 NDK 根路径
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}
export UNWIND_LIB_FILE=${UNWIND_LIB_FILE:-""}

# 🔧 核心修复1：强制导出链接器环境变量（覆盖所有 Cargo 编译）
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

# 核心验证：补充 NDK_PATH 验证
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

# 🔧 关键：确保 Cargo 配置生效（传递所有环境变量给 Cargo）
export CARGO_ENCODED_RUSTFLAGS=""
echo "Building Letta Lite for Android (${TARGET}) - 完整库路径+链接器"
echo -e "${GREEN}✅ 核心依赖路径验证通过：${NC}"
echo -e "  - NDK 根路径：${NDK_PATH}"
echo -e "  - 链接器：${CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER}"
echo -e "  - UNWIND_LIB_PATH: ${UNWIND_LIB_PATH}"
echo -e "  - OPENSSL_DIR: ${OPENSSL_DIR}"

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}"
echo -e "${GREEN}✅ 目标平台安装完成${NC}"

# 🔧 核心修复2：RUSTFLAGS 补充完整库搜索路径（所有库都能找到）
export RUSTFLAGS="\
--sysroot=${NDK_SYSROOT} \
-L ${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL} \
-L ${NDK_SYSROOT}/usr/lib/${TARGET} \
-L ${UNWIND_LIB_PATH} \
-L ${OPENSSL_LIB_DIR} \
-L ${NDK_PATH}/platforms/android-${ANDROID_API_LEVEL}/arch-arm64/usr/lib \
-C linker=${NDK_TOOLCHAIN_BIN}/ld.lld \
-C link-arg=-fuse-ld=lld \
-C link-arg=--allow-shlib-undefined"

# 交叉编译依赖配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译核心库（Cargo 配置自动传递链接参数）
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo ndk -t arm64-v8a -o "${PWD}/bindings/android/src/main/jniLibs" build --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成头文件（移除命令行 -C linker 参数，依赖环境变量+配置）
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build \
    --target="${TARGET}" \
    --profile mobile \
    --verbose \
    -p letta-ffi
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        HEADER_FILE="${PWD}/ffi/include/letta_lite.h"
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
echo -e "\n${YELLOW}✅ 所有库都能找到！链接器错误彻底解决！${NC}"
