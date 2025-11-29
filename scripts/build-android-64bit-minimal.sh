#!/usr/bin/env bash
set -euo pipefail

# 接收工作流传递的环境变量（包含项目内复制的库路径）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_PATH=${NDK_PATH:-""}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}
export SYS_LIB_COPY_PATH=${SYS_LIB_COPY_PATH:-""}
export UNWIND_LIB_COPY_PATH=${UNWIND_LIB_COPY_PATH:-""}

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

# 必需参数验证（确保项目内的库路径存在）
if [ -z "${SYS_LIB_COPY_PATH}" ] || [ -z "${UNWIND_LIB_COPY_PATH}" ] || [ ! -d "${SYS_LIB_COPY_PATH}" ]; then
    echo -e "${RED}Error: 系统库未复制到项目内${NC}"
    exit 1
fi

# OpenSSL 路径配置
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
echo -e "${GREEN}✅ 配置完成：${NC}"
echo -e "  - 项目内系统库路径：${SYS_LIB_COPY_PATH}"
echo -e "  - 项目内libunwind路径：${UNWIND_LIB_COPY_PATH}"
echo -e "  - OpenSSL 路径：${OPENSSL_LIB_DIR}"
echo -e "  - 链接器：${NDK_TOOLCHAIN_BIN}/ld.lld"

# 强制指定 RUSTFLAGS，指向项目内的库（双重保障）
export RUSTFLAGS="\
--sysroot=${NDK_SYSROOT} \
-L ${SYS_LIB_COPY_PATH} \
-L ${UNWIND_LIB_COPY_PATH} \
-L ${OPENSSL_LIB_DIR} \
-l:libunwind.a \
-l:libdl.so \
-l:liblog.so \
-l:libm.so \
-l:libc.so \
-C link-arg=--allow-shlib-undefined \
-C linker=${NDK_TOOLCHAIN_BIN}/ld.lld"

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}" 2>/dev/null || true
echo -e "${GREEN}✅ 目标平台准备完成${NC}"

# 交叉编译配置（适配 Workspace 子 crate）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译核心库（带 --verbose 查看参数传递，确保项目内库路径生效）
echo -e "\n${YELLOW}=== 编译核心库（letta-ffi） ===${NC}"
cargo build --workspace --target=${TARGET} --profile mobile --verbose -p letta-ffi
# 手动复制产物到 JNI 目录
mkdir -p "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
cp "${PWD}/target/${TARGET}/mobile/libletta_ffi.so" "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/"
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成头文件（完整步骤）
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build --workspace --target="${TARGET}" --profile mobile --verbose -p letta-ffi
HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
[ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
mkdir -p ffi/include && cp "$HEADER_FILE" ffi/include/
cp "$HEADER_FILE" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 编译 JNI 库（完整步骤，链接项目内的系统库）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"ffi/include" \
    -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" -lletta_ffi \
    -L"${SYS_LIB_COPY_PATH}" -ldl -llog -lm -lc \  # 链接项目内的
