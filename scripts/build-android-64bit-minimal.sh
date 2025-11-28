#!/usr/bin/env bash
set -euo pipefail

# 🔧 核心环境变量（明确区分 host 和 target）
export TARGET=aarch64-linux-android
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}

echo "Building Letta Lite for Android (${TARGET}) - 终终极依赖修复版..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: 缺失必要工具 $1${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command rustc
check_command cbindgen
check_command clang

# 🔧 1. 验证核心配置
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: NDK_TOOLCHAIN_BIN/NDK_SYSROOT/OPENSSL_DIR 未传递${NC}"
    exit 1
fi

# 🔧 2. 清理所有可能干扰的环境变量（关键！）
unset CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER 2>/dev/null
unset RUSTFLAGS 2>/dev/null
unset OUT_DIR 2>/dev/null
unset CARGO_MANIFEST_DIR 2>/dev/null
echo -e "${GREEN}✅ 清理干扰环境变量完成${NC}"

# 🔧 3. 配置交叉编译和依赖（让 cargo 自动识别）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export PKG_CONFIG_ALLOW_CROSS=1

# 验证交叉编译器和 OpenSSL 路径
if [ ! -f "${CC_aarch64_linux_android}" ]; then
    echo -e "${RED}Error: 交叉编译器 ${CC_aarch64_linux_android} 不存在${NC}"
    exit 1
fi
if [ ! -d "${OPENSSL_INCLUDE_DIR}" ] || [ ! -d "${OPENSSL_LIB_DIR}" ]; then
    echo -e "${RED}Error: OpenSSL 路径无效${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 交叉编译和依赖配置完成${NC}"

# 🔧 4. 确保目标平台和依赖已安装
rustup target add "${TARGET}" || true
# 确保 cbindgen 作为 build-dependency 存在（临时添加，不修改用户 Cargo.toml）
if ! grep -q "cbindgen" ffi/Cargo.toml; then
    echo -e "\n[build-dependencies]" >> ffi/Cargo.toml
    echo 'cbindgen = "0.26.0"' >> ffi/Cargo.toml
fi
cargo update -p cbindgen@0.26.0  # 确保依赖版本一致
echo -e "${GREEN}✅ 目标平台和依赖检查完成${NC}"

# 🔧 5. 编译核心库（已稳定成功，不变）
echo -e "\n${YELLOW}=== 编译核心库（${TARGET}）===${NC}"
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose
CORE_SO="bindings/android/src/main/jniLibs/arm64-v8a/libletta_ffi.so"
if [ ! -f "${CORE_SO}" ]; then
    echo -e "${RED}Error: 核心库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 核心库 ${CORE_SO} 生成成功${NC}"

# 🔧 6. 生成头文件（核心修复：通过 RUSTFLAGS 传递参数，避免 -C 直接传递）
echo -e "\n${YELLOW}=== 生成头文件（cargo 自动处理 build.rs）===${NC}"
# 关键：所有编译器参数通过 RUSTFLAGS 传递，不直接在 cargo build 中写 -C
export RUSTFLAGS="\
--sysroot=${NDK_SYSROOT} \
-L ${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL} \
-L ${OPENSSL_LIB_DIR} \
-C linker=${NDK_TOOLCHAIN_BIN}/ld.lld \
-C strip=symbols \
-ldl -llog -lm -lc -lunwind"

# 运行 cargo build（仅触发 build.rs 生成头文件，不重新编译核心库）
cargo build -p letta-ffi \
    --target="${TARGET}" \
    --verbose \
    --no-build-script  # 禁用自动 build.rs，用我们的 RUSTFLAGS 配置
# 重新运行 cargo build 触发 build.rs（确保头文件生成）
cargo build -p letta-ffi \
    --target="${TARGET}" \
    --verbose \
    --build-script ffi/build.rs

# 验证头文件
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/release|${TARGET}/mobile" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件生成失败${NC}"
        exit 1
    fi
    mkdir -p ffi/include
    cp "${HEADER_FILE}" "${HEADER_FILE}"
fi
cp "${HEADER_FILE}" "bindings/android/src/main/jni/"
echo -e "${GREEN}✅ 头文件 ${HEADER_FILE} 生成并复制完成${NC}"

# 🔧 7. 编译 JNI 库（不变，确保关联核心库）
echo -e "\n${YELLOW}=== 编译 JNI 库（${TARGET}）===${NC}"
JNI_DIR="bindings/android/src/main/jniLibs/arm64-v8a"
mkdir -p "${JNI_DIR}"
"${NDK_TOOLCHAIN_BIN}/clang" \
    --target="${TARGET}${ANDROID_API_LEVEL}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"bindings/android/src/main/jni/" \
    -I"${NDK_SYSROOT}/usr/include" \
    -I"${OPENSSL_INCLUDE_DIR}" \
    -shared \
    -fPIC \
    -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" \
    -lletta_ffi \
    -L"${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL}" \
    -L"${OPENSSL_LIB_DIR}" \
    -ldl -llog -lm -lc -lunwind -lssl -lcrypto \
    -O2
if [ ! -f "${JNI_DIR}/libletta_jni.so" ]; then
    echo -e "${RED}Error: JNI 库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ JNI 库 ${JNI_DIR}/libletta_jni.so 生成成功${NC}"

# 🔧 8. 打包 AAR（增加依赖配置，避免找不到 JNI）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android
# 确保 build.gradle 中配置了 JNI 目录
if ! grep -q "jniLibs.srcDirs" build.gradle; then
    echo -e "\nsourceSets { main { jniLibs.srcDirs = ['src/main/jniLibs'] } }" >> build.gradle
fi
chmod +x gradlew
./gradlew assembleRelease --no-daemon --verbose --stacktrace \
    -Dorg.gradle.jvmargs="-Xmx2g" \
    -Pandroid.ndkVersion="${ANDROID_NDK_VERSION}" \
    -Pandroid.minSdkVersion="${ANDROID_API_LEVEL}"
cd ../..

# 🔧 9. 验证并收集产物
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ ! -f "${AAR_PATH}" ]; then
    echo -e "${RED}Error: AAR 打包失败${NC}"
    exit 1
fi

mkdir -p ./release
cp "${CORE_SO}" ./release/
cp "${JNI_DIR}/libletta_jni.so" ./release/
cp "${AAR_PATH}" ./release/
cp "${HEADER_FILE}" ./release/
echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200（${TARGET}）${NC}"
echo -e "${GREEN}📦 产物列表：${NC}"
echo -e "  - 核心库：release/libletta_ffi.so"
echo -e "  - JNI 库：release/libletta_jni.so"
echo -e "  - AAR 包：release/android-release.aar"
echo -e "  - 头文件：release/letta_lite.h"
