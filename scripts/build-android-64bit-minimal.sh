#!/usr/bin/env bash
set -euo pipefail

# 强制锁定目标平台（仅 arm64-v8a，适配天玑1200）
export TARGET="aarch64-linux-android"
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_HOME=${NDK_PATH:-"/usr/local/lib/android/sdk/ndk/27.3.13750724"}
export OPENSSL_DIR=${OPENSSL_INSTALL_DIR:-"/home/runner/work/letta-lite/openssl-install"}
export SYS_LIB_PATH=${SYS_LIB_PATH:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/${TARGET}/lib"

# 自动推导核心路径
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export PROJECT_SYS_LIB_DIR="${PWD}/dependencies/lib"

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查（确保 cbindgen 已安装）
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
check_command cbindgen  # 确保 cbindgen 工具可用

# 验证 CI 环境变量路径
echo -e "\n${YELLOW}=== 验证 CI 环境变量路径 ===${NC}"
[ -z "${NDK_TOOLCHAIN_BIN}" ] && { echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 未提供${NC}"; exit 1; }
[ -z "${NDK_SYSROOT}" ] && { echo -e "${RED}Error: NDK_SYSROOT 未提供${NC}"; exit 1; }
[ -z "${SYS_LIB_PATH}" ] && { echo -e "${RED}Error: SYS_LIB_PATH 未提供${NC}"; exit 1; }
[ ! -d "${RUST_STD_PATH}" ] && { echo -e "${RED}Error: Rust 标准库路径不存在：${RUST_STD_PATH}${NC}"; exit 1; }
[ ! -d "${OPENSSL_DIR}/lib" ] && { echo -e "${RED}Error: OpenSSL 库路径不存在${NC}"; exit 1; }
echo -e "${GREEN}✅ 所有 CI 路径验证通过${NC}"

# 核心 RUSTFLAGS（无无效参数）
export RUSTFLAGS="--sysroot=${NDK_SYSROOT} -L ${RUST_STD_PATH} -L ${SYS_LIB_PATH} -L ${OPENSSL_DIR}/lib -L ${PROJECT_SYS_LIB_DIR}/sys $( [ -n "${UNWIND_LIB_PATH}" ] && echo "-L ${UNWIND_LIB_PATH}" ) -C panic=abort"

# 交叉编译工具链配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 构建配置汇总
echo -e "\n${YELLOW}=== 构建配置汇总（最终最终稳定版） ===${NC}"
echo -e "  目标平台：${TARGET}（仅 arm64-v8a）"
echo -e "  Android API：${ANDROID_API_LEVEL}"
echo -e "  编译模式：panic=abort + 命令行 cbindgen 生成头文件"

# 验证目标平台标准库
echo -e "\n${YELLOW}=== 验证目标平台标准库 ===${NC}"
if ! rustup target list | grep -q "${TARGET} (installed)"; then
    echo -e "${YELLOW}安装目标平台 ${TARGET}...${NC}"
    rustup target add "${TARGET}" --toolchain stable || exit 1
fi
echo -e "${GREEN}✅ 目标平台标准库已就绪${NC}"

# 编译核心库
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo ndk --platform "${ANDROID_API_LEVEL}" -t arm64-v8a -o "${PWD}/bindings/android/src/main/jniLibs" build --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
if [ ! -f "${CORE_SO}" ]; then
    echo -e "${RED}Error: 核心库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 🔧 修复：直接用 cbindgen 命令行生成头文件（无需 crate feature）
echo -e "\n${YELLOW}=== 生成 C 头文件（命令行模式） ===${NC}"
mkdir -p ffi/include "${PWD}/bindings/android/src/main/jni"
# 直接调用 cbindgen 工具，指定 crate、语言和输出路径
cbindgen --crate letta-ffi --lang c --output ffi/include/letta_lite.h --verbose
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    echo -e "${YELLOW}⚠️  头文件生成失败，尝试搜索备用路径...${NC}"
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
    [ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
    cp "${HEADER_FILE}" ffi/include/
fi
# 复制头文件到 JNI 目录
cp "${HEADER_FILE}" "${PWD}/bindings/android/src/main/jni/"
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 编译 JNI 库
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
"${CC_aarch64_linux_android}" --sysroot="${NDK_SYSROOT}" -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" -I"${NDK_SYSROOT}/usr/include" -I"ffi/include" -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" "bindings/android/src/main/jni/letta_jni.c" -L"${JNI_DIR}" -L"${OPENSSL_DIR}/lib" -L "${SYS_LIB_PATH}" -lletta_ffi -lssl -lcrypto -ldl -llog -lm -lc -O2
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
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" -Pandroid.compileSdkVersion=33 -Pandroid.minSdkVersion=24 -Pandroid.targetSdkVersion=33
else
    echo -e "${RED}Error: 未找到 gradlew，AAR 打包失败${NC}"
    exit 1
fi
cd ../..

# 收集产物
echo -e "\n${YELLOW}=== 收集产物 ===${NC}"
mkdir -p "${PWD}/release"
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ ! -f "${AAR_PATH}" ]; then
    AAR_PATH=$(find "${PWD}/bindings/android" -name "*.aar" | grep -E "release" | head -n 1)
    [ -z "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR 未找到${NC}"; exit 1; }
fi
cp "${CORE_SO}" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "${AAR_PATH}" "${PWD}/release/letta-lite-android.aar"
cp "${HEADER_FILE}" "${PWD}/release/"
cp "${PWD}/build.log" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配 NDK 27 + 天玑1200 + API 24${NC}"
echo -e "${GREEN}📦 最终产物清单（release 目录）：${NC}"
ls -l "${PWD}/release/"
