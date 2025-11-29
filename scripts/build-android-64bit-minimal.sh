#!/usr/bin/env bash
set -euo pipefail

# 复用 CI 已验证的 NDK 路径
export NDK_HOME="${NDK_HOME:-"/usr/local/lib/android/sdk/ndk/27.3.13750724"}"
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export OPENSSL_DIR=${OPENSSL_DIR:-"/home/runner/work/letta-lite/openssl-install"}

# 自动推导核心路径
export NDK_TOOLCHAIN_BIN="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin"
export NDK_SYSROOT="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export PROJECT_SYS_LIB_DIR="${PWD}/dependencies/lib"
export UNWIND_LIB_SEARCH_PATHS=(
    "${PROJECT_SYS_LIB_DIR}/unwind"
    "${NDK_HOME}"
)

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

# 搜索 libunwind 静态库
echo -e "\n${YELLOW}=== 搜索 libunwind 静态库（项目内+NDK） ===${NC}"
UNWIND_LIB_FILE=""
for path in "${UNWIND_LIB_SEARCH_PATHS[@]}"; do
    echo -e "  正在搜索：$path"
    found=$(find "$path" -name "libunwind.a" -type f | head -n 1)
    if [ -n "${found}" ] && [ -f "${found}" ]; then
        UNWIND_LIB_FILE="${found}"
        break
    fi
done

# 双重保险：启用 panic=abort
if [ -z "${UNWIND_LIB_FILE}" ]; then
    echo -e "${YELLOW}⚠️  未找到 libunwind.a，启用 panic=abort 模式${NC}"
    export UNWIND_LIB_PATH=""
else
    UNWIND_LIB_PATH=$(dirname "${UNWIND_LIB_FILE}")
    echo -e "${GREEN}✅ 找到 libunwind 静态库：${UNWIND_LIB_FILE}${NC}"
fi

# 必需路径验证
if [ ! -d "${NDK_TOOLCHAIN_BIN}" ] || [ ! -d "${NDK_SYSROOT}" ]; then
    echo -e "${RED}Error: NDK 路径不存在！${NC}"
    exit 1
fi
if [ ! -d "${OPENSSL_DIR}/lib" ] || [ ! -d "${OPENSSL_DIR}/include" ]; then
    echo -e "${RED}Error: OpenSSL 路径不存在！${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 所有核心路径验证通过${NC}"

# OpenSSL 配置
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"

# 构建配置汇总
echo -e "\n${YELLOW}=== 构建配置汇总（NDK 27 + 语法修复） ===${NC}"
echo -e "  目标平台：${TARGET}"
echo -e "  NDK 路径：${NDK_HOME}"
echo -e "  模式：$( [ -n "${UNWIND_LIB_FILE}" ] && echo "静态链接 libunwind" || echo "panic=abort" )"

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
if ! rustup target list | grep -q "${TARGET} (installed)"; then
    rustup target add "${TARGET}" --toolchain stable || exit 1
fi
echo -e "${GREEN}✅ 目标平台标准库已就绪${NC}"

# 🔧 核心修复：清理 RUSTFLAGS 注释和无效字符，确保参数格式正确
RUSTFLAGS_BASE="--sysroot=${NDK_SYSROOT} -L ${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL} -L ${OPENSSL_LIB_DIR} -L ${PROJECT_SYS_LIB_DIR}/sys -C panic=abort -C link-arg=--allow-shlib-undefined -C linker=${NDK_TOOLCHAIN_BIN}/ld.lld"

# 有 libunwind 则添加路径
if [ -n "${UNWIND_LIB_PATH}" ]; then
    export RUSTFLAGS="${RUSTFLAGS_BASE} -L ${UNWIND_LIB_PATH}"
else
    export RUSTFLAGS="${RUSTFLAGS_BASE}"
fi

# 交叉编译工具链配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译核心库
echo -e "\n${YELLOW}=== 编译核心库（语法修复版） ===${NC}"
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
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
fi
if [ -z "${HEADER_FILE}" ] || [ ! -f "${HEADER_FILE}" ]; then
    echo -e "${RED}Error: 头文件生成失败${NC}"
    exit 1
fi
mkdir -p ffi/include && cp "${HEADER_FILE}" ffi/include/
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

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
    -L "${PROJECT_SYS_LIB_DIR}/sys" \
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
cd bindings/android || { echo -e "${RED}Error: 进入 Android 目录失败${NC}"; exit 1; }
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
else
    gradle assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
fi
cd ../..

# 验证 AAR 产物
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ ! -f "${AAR_PATH}" ]; then
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

echo -e "\n${GREEN}🎉 所有产物生成成功！适配 NDK 27 + 天玑1200${NC}"
echo -e "${GREEN}📦 最终产物清单（release 目录）：${NC}"
ls -l "${PWD}/release/"
