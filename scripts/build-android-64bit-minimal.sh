#!/usr/bin/env bash
set -euo pipefail

# 从 Workflow 接收环境变量（仅需传递核心变量）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_HOME=${NDK_HOME:-"/usr/local/lib/android/sdk/ndk/25.2.9519653"}  # NDK 25 默认路径
export OPENSSL_DIR=${OPENSSL_DIR:-"/home/runner/work/letta-lite/openssl-install"}

# 自动推导核心路径（不依赖 clang 版本路径）
export NDK_TOOLCHAIN_BIN="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin"
export NDK_SYSROOT="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

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
check_command readelf

# 🔧 核心修复：直接全局搜索 NDK 25 中的 libunwind.a（跳过固定路径）
echo -e "\n${YELLOW}=== 全局搜索 NDK 25 libunwind 静态库 ===${NC}"
# 直接从 NDK 根目录搜索，只找 aarch64 架构的 libunwind.a
UNWIND_LIB_FILE=$(find "$NDK_HOME" -name "libunwind.a" -path "*/aarch64/*" -type f | head -n 1)
if [ -z "${UNWIND_LIB_FILE}" ] || [ ! -f "${UNWIND_LIB_FILE}" ]; then
    # 备用：放宽搜索条件，不限制架构路径（防止 NDK 目录结构特殊）
    echo -e "${YELLOW}⚠️  未找到 aarch64 架构 libunwind，搜索所有架构...${NC}"
    UNWIND_LIB_FILE=$(find "$NDK_HOME" -name "libunwind.a" -type f | head -n 1)
    if [ -z "${UNWIND_LIB_FILE}" ]; then
        echo -e "${RED}Error: NDK 25 中未找到 libunwind.a！${NC}"
        echo -e "  搜索范围：$NDK_HOME"
        exit 1
    fi
fi
# 自动获取实际路径
UNWIND_LIB_PATH=$(dirname "${UNWIND_LIB_FILE}")
echo -e "${GREEN}✅ 全局搜索找到 libunwind 静态库：${NC}"
echo -e "  - 路径：${UNWIND_LIB_PATH}"
echo -e "  - 文件：${UNWIND_LIB_FILE}"

# 必需环境变量验证
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: 必需环境变量未传递${NC}"
    exit 1
fi

# OpenSSL 路径配置
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
if [ ! -d "${OPENSSL_LIB_DIR}" ] || [ ! -d "${OPENSSL_INCLUDE_DIR}" ]; then
    echo -e "${RED}Error: OpenSSL 路径不存在！${NC}"
    exit 1
fi
echo -e "${GREEN}✅ OPENSSL 配置完成：${NC}"
echo -e "  - 库路径：${OPENSSL_LIB_DIR}"
echo -e "  - 头文件路径：${OPENSSL_INCLUDE_DIR}"

# 构建配置汇总
echo -e "\n${YELLOW}=== 构建配置汇总（NDK 25 + 全局搜索） ===${NC}"
echo -e "  目标平台：${TARGET}"
echo -e "  Android API：${ANDROID_API_LEVEL}"
echo -e "  NDK 路径：${NDK_HOME}"
echo -e "  libunwind：${UNWIND_LIB_FILE}"
echo -e "  构建模式：全局搜索 + build.rs 静态链接"

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
if ! rustup target list | grep -q "${TARGET} (installed)"; then
    rustup target add "${TARGET}" --toolchain stable || {
        echo -e "${RED}Error: 目标平台 ${TARGET} 安装失败${NC}"
        exit 1
    }
fi
echo -e "${GREEN}✅ 目标平台标准库已就绪${NC}"

# RUSTFLAGS 仅保留路径配置，libunwind 链接交给 build.rs
export RUSTFLAGS="\
--sysroot=${NDK_SYSROOT} \
-L ${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL} \
-L ${OPENSSL_LIB_DIR} \
-L ${UNWIND_LIB_PATH} \
-C link-arg=--allow-shlib-undefined \
-C linker=${NDK_TOOLCHAIN_BIN}/ld.lld"

# 交叉编译工具链配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 传递 libunwind 路径给 build.rs，编译核心库
echo -e "\n${YELLOW}=== 编译核心库（build.rs 静态链接 libunwind） ===${NC}"
cargo ndk \
    -t arm64-v8a \
    -o "${PWD}/bindings/android/src/main/jniLibs" \
    build --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
if [ ! -f "${CORE_SO}" ]; then
    echo -e "${RED}Error: 核心库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成 C 头文件
echo -e "\n${YELLOW}=== 生成 C 头文件 ===${NC}"
cargo build --target="${TARGET}" --profile mobile --features cbindgen --verbose -p letta-ffi
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    echo -e "${YELLOW}⚠️  查找自动生成的头文件...${NC}"
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
fi
if [ -z "${HEADER_FILE}" ] || [ ! -f "${HEADER_FILE}" ]; then
    echo -e "${RED}Error: 头文件生成失败${NC}"
    exit 1
fi
mkdir -p ffi/include && cp "${HEADER_FILE}" ffi/include/
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 验证 libunwind 静态链接
echo -e "\n${YELLOW}=== 静态链接验证 ===${NC}"
if readelf -d "${CORE_SO}" | grep -qi "unwind"; then
    echo -e "${YELLOW}⚠️  警告：检测到 libunwind 动态依赖（检查 build.rs 配置）${NC}"
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
    -L"${JNI_DIR}" \
    -L"${OPENSSL_LIB_DIR}" \
    -lletta_ffi \
    -lssl -lcrypto \
    -ldl -llog -lm -lc \
    -O2
if [ ! -f "${JNI_DIR}/libletta_jni.so" ]; then
    echo -e "${RED}Error: JNI 库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ JNI 库生成成功：${JNI_DIR}/libletta_jni.so${NC}"

# 打包 AAR
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android || { echo -e "${RED}Error: 进入 Android 项目目录失败${NC}"; exit 1; }
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
else
    echo -e "${YELLOW}使用系统 gradle 打包...${NC}"
    gradle assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
fi
cd ../..

# 验证 AAR 产物
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ ! -f "${AAR_PATH}" ]; then
    echo -e "${YELLOW}⚠️  搜索 release 版本 AAR...${NC}"
    AAR_PATH=$(find "${PWD}/bindings/android" -name "*.aar" | grep -E "release" | head -n 1)
    [ -z "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR 打包失败${NC}"; exit 1; }
fi
echo -e "${GREEN}✅ AAR 打包成功：${AAR_PATH}${NC}"

# 收集产物
mkdir -p "${PWD}/release"
cp "${CORE_SO}" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "${AAR_PATH}" "${PWD}/release/letta-lite-android.aar"
cp "${HEADER_FILE}" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配 NDK 25 + 天玑1200${NC}"
echo -e "${GREEN}📦 最终产物清单（release 目录）：${NC}"
ls -l "${PWD}/release/"
