#!/usr/bin/env bash
set -euo pipefail

# 简化环境变量（千问建议：不用手动配置NDK路径）
export TARGET="arm64-linux-android"
export ANDROID_API_LEVEL="31"
export OPENSSL_DIR="${PWD}/openssl-install"
export UNWIND_LIB_PATH="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux/aarch64"
export UNWIND_LIB_FILE="${UNWIND_LIB_PATH}/libunwind.a"

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 简单验证依赖
if [ ! -f "${UNWIND_LIB_FILE}" ]; then
    echo -e "${RED}Error: 未找到 libunwind.a${NC}"
    exit 1
fi

if [ ! -d "${OPENSSL_DIR}/lib" ]; then
    echo -e "${RED}Error: OpenSSL 安装失败${NC}"
    exit 1
fi

# 编译核心库（千问建议：简化命令）
echo -e "\n${YELLOW}=== 编译核心库 ===${NC}"
cargo ndk -t arm64-v8a -o "${PWD}/bindings/android/src/main/jniLibs" build --release -p letta-ffi

# 生成头文件（简化命令，自动找build.rs生成的文件）
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
cargo build --target="${TARGET}" --release -p letta-ffi
HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/release" | head -n 1)
mkdir -p ffi/include && cp "${HEADER_FILE}" ffi/include/
cp "${HEADER_FILE}" bindings/android/src/main/jni/

# 编译JNI库
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
CC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/${TARGET}31-clang"
"${CC}" \
    --sysroot="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot" \
    -I"${JAVA_HOME}/include" \
    -I"${JAVA_HOME}/include/linux" \
    -I"ffi/include" \
    -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" -lletta_ffi -L"${OPENSSL_DIR}/lib" \
    -ldl -llog -lssl -lcrypto -O2

# 打包AAR
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android
./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
cd ../..

# 收集产物
mkdir -p ./release
cp "${JNI_DIR}/libletta_ffi.so" ./release/
cp "${JNI_DIR}/libletta_jni.so" ./release/
cp "bindings/android/build/outputs/aar/android-release.aar" ./release/
cp "${HEADER_FILE}" ./release/

echo -e "\n${GREEN}🎉 所有产物生成成功！${NC}"
echo -e "${GREEN}📦 产物在 release 目录下${NC}"
