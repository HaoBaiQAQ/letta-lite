#!/usr/bin/env bash
set -euo pipefail

# 接收工作流传递的环境变量
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_PATH=${NDK_PATH:-""}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}

# 强制链接器（工作流已配置，这里呼应）
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

# 必需参数验证
if [ -z "${NDK_PATH}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: 工作流未传递必需环境变量${NC}"
    exit 1
fi

# OpenSSL 路径配置
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
echo -e "${GREEN}✅ 配置完成：${NC}"
echo -e "  - NDK 路径：${NDK_PATH}"
echo -e "  - OpenSSL 路径：${OPENSSL_LIB_DIR}"
echo -e "  - 链接器：${CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER}"

# 🔧 唯一修改：删掉多余的 -C link-arg=-fuse-ld=lld
export RUSTFLAGS="-C linker=${NDK_TOOLCHAIN_BIN}/ld.lld"

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}" 2>/dev/null || true
echo -e "${GREEN}✅ 目标平台准备完成${NC}"

# 交叉编译配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译核心库
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo ndk -t arm64-v8a -o "${PWD}/bindings/android/src/main/jniLibs" build --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成头文件
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build --target="${TARGET}" --profile mobile --verbose -p letta-ffi
HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
[ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
mkdir -p ffi/include && cp "$HEADER_FILE" ffi/include/
cp "$HEADER_FILE" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 编译 JNI 库
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

# 打包 AAR
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android && ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" && cd ../..
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
[ ! -f "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR 打包失败${NC}"; exit 1; }
echo -e "${GREEN}✅ AAR 打包成功${NC}"

# 收集产物
mkdir -p "${PWD}/release"
cp "${CORE_SO}" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "${AAR_PATH}" "${PWD}/release/"
cp "${HEADER_FILE}" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27${NC}"
echo -e "${GREEN}📦 产物清单（release 目录）：${NC}"
echo -e "  1. libletta_ffi.so（核心库）"
echo -e "  2. libletta_jni.so（JNI 库）"
echo -e "  3. letta-lite-android.aar（Android 库）"
echo -e "  4. letta_lite.h（C 接口头文件）"
echo -e "  5. build.log（编译日志）"
