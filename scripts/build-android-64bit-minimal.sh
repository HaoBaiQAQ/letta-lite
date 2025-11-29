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

# 颜色配置（删除了多余的 linker 环境变量导出）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查（保留 cargo-ndk 检查，避免安装缺失报错）
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
echo -e "  - 链接器：${NDK_TOOLCHAIN_BIN}/ld.lld"

# 🔧 修改1：RUSTFLAGS 留空，避免重复指定 linker
export RUSTFLAGS=""

# 安装目标平台标准库
echo -e "\n${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}" 2>/dev/null || true
echo -e "${GREEN}✅ 目标平台准备完成${NC}"

# 交叉编译配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 🔧 修改2：替换 cargo ndk 命令，手动指定 linker 和路径，消除冲突
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo build --target=${TARGET} --profile mobile --verbose -p letta-ffi \
  --config "target.${TARGET}.linker = '${NDK_TOOLCHAIN_BIN}/ld.lld'" \
  --config "target.${TARGET}.rustflags = [
    '--sysroot=${NDK_SYSROOT}',
    '-L', '${NDK_SYSROOT}/usr/lib/aarch64-linux-android/24',
    '-L', '${UNWIND_LIB_PATH}',
    '-L', '${OPENSSL_LIB_DIR}',
    '-l:libunwind.a',
    '-l:libdl.so',
    '-l:liblog.so',
    '-l:libm.so',
    '-l:libc.so',
    '-C', 'link-arg=--allow-shlib-undefined'
  ]"
# 手动复制产物到 JNI 目录（原 cargo ndk 自动完成的工作）
mkdir -p "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
cp "${PWD}/target/${TARGET}/mobile/libletta_ffi.so" "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/"
CORE_SO="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成头文件（保持不变）
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build --target="${TARGET}" --profile mobile --verbose -p letta-ffi
HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
[ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
mkdir -p ffi/include && cp "$HEADER_FILE" ffi/include/
cp "$HEADER_FILE" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 编译 JNI 库（保持不变）
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

# 打包 AAR（保持不变）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android && ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" && cd ../..
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
[ ! -f "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR 打包失败${NC}"; exit 1; }
echo -e "${GREEN}✅ AAR 打包成功${NC}"

# 收集产物（保持不变）
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
