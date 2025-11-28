#!/usr/bin/env bash
set -euo pipefail

# 🔧 核心环境变量（明确区分 host 和 target）
export TARGET=aarch64-linux-android  # 目标平台（Android 天玑1200）
export HOST=$(rustc -vV | grep host | awk '{print $2}')  # 构建机器平台（x86_64-linux-gnu）
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}

echo "Building Letta Lite for Android (${TARGET}) - 终极全量修复版..."

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查（补全所有依赖）
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: 缺失必要工具 $1，请检查环境${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command rustc
check_command cbindgen
check_command clang
check_command find
check_command awk

# 🔧 1. 验证核心配置（避免空值）
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ] || [ -z "${OPENSSL_DIR}" ]; then
    echo -e "${RED}Error: NDK_TOOLCHAIN_BIN/NDK_SYSROOT/OPENSSL_DIR 未传递${NC}"
    exit 1
fi

# 🔧 2. 清理污染环境变量（避免交叉编译干扰）
unset CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER 2>/dev/null
unset RUSTFLAGS 2>/dev/null
echo -e "${GREEN}✅ 清理污染环境变量完成${NC}"

# 🔧 3. 配置交叉编译器（仅用于目标代码编译）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
if [ ! -f "${CC_aarch64_linux_android}" ]; then
    echo -e "${RED}Error: 交叉编译器 ${CC_aarch64_linux_android} 不存在${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 交叉编译器配置完成${NC}"

# 🔧 4. 配置 OpenSSL（目标平台依赖）
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export PKG_CONFIG_ALLOW_CROSS=1
if [ ! -d "${OPENSSL_INCLUDE_DIR}" ] || [ ! -d "${OPENSSL_LIB_DIR}" ]; then
    echo -e "${RED}Error: OpenSSL 路径无效${NC}"
    exit 1
fi
echo -e "${GREEN}✅ OpenSSL 配置完成${NC}"

# 🔧 5. 安装依赖（确保 cbindgen 和 target 已安装）
rustup target add "${TARGET}" || true  # 确保 Android 目标已安装
cargo install cbindgen --version 0.26.0 --force  # 固定版本，避免兼容性问题
echo -e "${GREEN}✅ 依赖工具安装完成${NC}"

# 🔧 6. 编译核心库（目标：Android aarch64，已稳定成功）
echo -e "\n${YELLOW}=== 开始编译核心库（${TARGET}）===${NC}"
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

# 🔧 7. 生成头文件（核心修复：build.rs 编译为 host 目标，而非 Android）
echo -e "\n${YELLOW}=== 开始生成头文件（build.rs 目标：${HOST}）===${NC}"
BUILD_SCRIPT="ffi/build.rs"
OUT_DIR="${PWD}/target/${HOST}/release/build/letta-ffi-$(uuidgen | head -c 16)/out"
mkdir -p "${OUT_DIR}"

# 关键修复1：找到 cbindgen 的依赖库路径（自动查找，避免硬编码）
CBINDGEN_CRATE=$(cargo metadata --format-version=1 | jq -r '.packages[] | select(.name == "cbindgen") | .manifest_path' | xargs dirname)
CBINDGEN_LIB_DIR="${CBINDGEN_CRATE}/target/${HOST}/release/deps"
if [ ! -d "${CBINDGEN_LIB_DIR}" ]; then
    # 若未编译，先编译 cbindgen
    cargo build -p cbindgen --release --target "${HOST}"
fi

# 关键修复2：Rust 标准库路径（使用 host 的 sysroot，不是 NDK 的）
RUST_SYSROOT=$(rustc --print sysroot)
COMPILER_BUILTINS_LIB="${RUST_SYSROOT}/lib/rustlib/${HOST}/lib"

# 关键修复3：手动编译 build.rs（目标：host，运行在构建机器上）
rustc \
    --edition=2018 \
    --target="${HOST}" \  # 核心！build.rs 编译为 host 目标，不是 Android
    --sysroot="${RUST_SYSROOT}" \  # 使用 Rust 自带的 sysroot，找到 std 库
    -L "${CBINDGEN_LIB_DIR}" \  # 传递 cbindgen 依赖库路径
    -L "${COMPILER_BUILTINS_LIB}" \  # 解决 compiler_builtins 缺失
    --extern cbindgen="${CBINDGEN_LIB_DIR}/libcbindgen-$(ls ${CBINDGEN_LIB_DIR} | grep -E 'libcbindgen-.*\.rlib' | head -n 1)" \
    -o "${OUT_DIR}/build-script-build" \
    "${BUILD_SCRIPT}" \
    --cfg procmacro2_semver_exempt \
    --cfg rustix_use_libc \
    -O  # 优化 build.rs，加快执行速度

# 执行 build.rs 生成头文件
export CARGO_MANIFEST_DIR="${PWD}/ffi"
export CARGO_PKG_NAME="letta-ffi"
export CARGO_PKG_VERSION="0.1.0"
"${OUT_DIR}/build-script-build"

# 验证头文件（兼容自动生成的路径）
HEADER_FILE="${PWD}/ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -v "debug" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件生成失败${NC}"
        exit 1
    fi
    cp "${HEADER_FILE}" "${PWD}/ffi/include/"
fi
cp "${HEADER_FILE}" "bindings/android/src/main/jni/"
echo -e "${GREEN}✅ 头文件 ${HEADER_FILE} 生成并复制完成${NC}"

# 🔧 8. 编译 JNI 库（目标：Android aarch64，关联核心库）
echo -e "\n${YELLOW}=== 开始编译 JNI 库（${TARGET}）===${NC}"
JNI_DIR="bindings/android/src/main/jniLibs/arm64-v8a"
mkdir -p "${JNI_DIR}"
"${NDK_TOOLCHAIN_BIN}/clang" \
    --target="${TARGET}${ANDROID_API_LEVEL}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"bindings/android/src/main/jni/" \
    -I"${NDK_SYSROOT}/usr/include" \
    -shared \
    -fPIC \
    -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" \
    -lletta_ffi \
    -L"${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL}" \
    -ldl -llog -lm -lc -lunwind \
    -O2  # 优化 JNI 库体积和性能

if [ ! -f "${JNI_DIR}/libletta_jni.so" ]; then
    echo -e "${RED}Error: JNI 库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ JNI 库 ${JNI_DIR}/libletta_jni.so 生成成功${NC}"

# 🔧 9. 打包 AAR（自动处理依赖和配置）
echo -e "\n${YELLOW}=== 开始打包 AAR ===${NC}"
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --no-daemon --verbose --stacktrace \
        -Dorg.gradle.jvmargs="-Xmx2g" \  # 增加堆内存，避免 OOM
        -Pandroid.ndkVersion="${ANDROID_NDK_VERSION}" \
        -Pandroid.minSdkVersion="${ANDROID_API_LEVEL}"
else
    echo -e "${RED}Error: gradlew 未找到${NC}"
    exit 1
fi
cd ../..

# 🔧 10. 验证最终产物（确保所有文件都存在）
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ ! -f "${AAR_PATH}" ]; then
    echo -e "${RED}Error: AAR 打包失败${NC}"
    exit 1
fi

# 收集产物（统一输出到 release 目录）
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
