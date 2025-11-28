#!/usr/bin/env bash
set -euo pipefail

# 🔧 纯开源项目配置（参考Tauri交叉编译规范）
export TARGET=aarch64-linux-android
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}

# 核心：用环境变量指定linker（绕开-- -C bug，开源项目通用方案）
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_TOOLCHAIN_BIN}/ld.lld"

echo "Building Letta Lite for Android (${TARGET}) - 开源最小化方案版..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 仅检查必需工具（不额外安装，避免干扰）
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

# 🔧 1. 仅验证必需路径（不做多余检查）
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: 必需参数未传递${NC}"
    exit 1
fi

# 🔧 2. 安装目标平台（不验证路径，让Rustc自动查找）
echo -e "${YELLOW}=== 安装目标平台标准库 ===${NC}"
rustup target add "${TARGET}"  # 去掉|| true，安装失败直接报错，不隐瞒
echo -e "${GREEN}✅ 目标平台安装完成${NC}"

# 🔧 3. 配置交叉编译依赖（仅必需环境变量）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export PKG_CONFIG_ALLOW_CROSS=1

# 🔧 4. 编译核心库（稳定无错，保留）
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo ndk -t arm64-v8a -o bindings/android/src/main/jniLibs build -p letta-ffi --profile mobile --verbose
CORE_SO="bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功${NC}"

# 🔧 5. 生成头文件（Cargo自动处理，不干预）
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build -p letta-ffi --target="${TARGET}" --profile mobile --verbose
HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
[ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
mkdir -p ffi/include && cp "${HEADER_FILE}" ffi/include/
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件生成成功${NC}"

# 🔧 6. 编译JNI库（NDK官方命令）
echo -e "\n${YELLOW}=== 编译JNI库 ===${NC}"
JNI_DIR="bindings/android/src/main/jniLibs/arm64-v8a"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"bindings/android/src/main/jni/" \
    -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" -lletta_ffi -L"${OPENSSL_LIB_DIR}" \
    -ldl -llog -lssl -lcrypto -O2
[ ! -f "${JNI_DIR}/libletta_jni.so" ] && { echo -e "${RED}Error: JNI库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI库生成成功${NC}"

# 🔧 7. 打包AAR（不修改任何配置）
echo -e "\n${YELLOW}=== 打包AAR ===${NC}"
cd bindings/android && chmod +x gradlew && ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
cd ../..
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
[ ! -f "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR打包失败${NC}"; exit 1; }

# 收集产物
mkdir -p ./release
cp "${CORE_SO}" ./release/ && cp "${JNI_DIR}/libletta_jni.so" ./release/ && cp "${AAR_PATH}" ./release/ && cp "${HEADER_FILE}" ./release/

echo -e "\n${GREEN}🎉 所有产物生成成功！${NC}"
echo -e "${GREEN}📦 产物：release/libletta_ffi.so、libletta_jni.so、android-release.aar、letta_lite.h${NC}"
