#!/usr/bin/env bash
set -euo pipefail

# 🔧 核心环境变量
export TARGET=aarch64-linux-android
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}
export NDK_SYSROOT=${NDK_SYSROOT:-""}
export OPENSSL_DIR=${OPENSSL_DIR:-""}

echo "Building Letta Lite for Android (${TARGET}) - 无无效参数最终版..."

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

# 🔧 2. 清理干扰环境变量
unset CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER 2>/dev/null
unset RUSTFLAGS 2>/dev/null
echo -e "${GREEN}✅ 清理干扰环境变量完成${NC}"

# 🔧 3. 配置交叉编译和依赖
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export PKG_CONFIG_ALLOW_CROSS=1

# 验证路径有效性
if [ ! -f "${CC_aarch64_linux_android}" ]; then
    echo -e "${RED}Error: 交叉编译器 ${CC_aarch64_linux_android} 不存在${NC}"
    exit 1
fi
if [ ! -d "${OPENSSL_INCLUDE_DIR}" ] || [ ! -d "${OPENSSL_LIB_DIR}" ]; then
    echo -e "${RED}Error: OpenSSL 路径无效${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 交叉编译和依赖配置完成${NC}"

# 🔧 4. 确保目标平台和 cbindgen 依赖
rustup target add "${TARGET}" || true
# 确保 build.rs 被 cargo 识别（如果 ffi/Cargo.toml 没有配置 build，手动添加）
if ! grep -q '^build = "build.rs"' ffi/Cargo.toml; then
    echo -e "\nbuild = \"build.rs\"" >> ffi/Cargo.toml
fi
# 确保 cbindgen 作为 build-dependency
if ! grep -q "cbindgen" ffi/Cargo.toml; then
    echo -e "\n[build-dependencies]" >> ffi/Cargo.toml
    echo 'cbindgen = "0.26.0"' >> ffi/Cargo.toml
fi
cargo update -p cbindgen@0.26.0
echo -e "${GREEN}✅ 目标平台和依赖准备完成${NC}"

# 🔧 5. 编译核心库（已稳定成功）
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

# 🔧 6. 生成头文件（核心简化：cargo 自动运行 build.rs）
echo -e "\n${YELLOW}=== 生成头文件（自动触发 build.rs）===${NC}"
# 仅通过 RUSTFLAGS 传递编译器参数，无其他无效参数
export RUSTFLAGS="--sysroot=${NDK_SYSROOT} -L ${NDK_SYSROOT}/usr/lib/${TARGET}/${ANDROID_API_LEVEL} -L ${OPENSSL_LIB_DIR} -C linker=${NDK_TOOLCHAIN_BIN}/ld.lld -ldl -llog -lm -lc -lunwind"

# 运行 cargo build 触发 build.rs（--target 确保和核心库编译目标一致）
cargo build -p letta-ffi \
    --target="${TARGET}" \
    --verbose \
    --profile mobile  # 和核心库用相同 profile，避免重复编译

# 验证头文件
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    HEADER_FILE=$(find "${PWD}/target/${TARGET}/mobile/build/letta-ffi-"*"/out" -name "letta_lite.h" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件生成失败${NC}"
        exit 1
    fi
    mkdir -p ffi/include
    cp "${HEADER_FILE}" "${HEADER_FILE}"
fi
cp "${HEADER_FILE}" "bindings/android/src/main/jni/"
echo -e "${GREEN}✅ 头文件 ${HEADER_FILE} 生成并复制完成${NC}"

# 🔧 7. 编译 JNI 库（关联核心库和依赖）
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

# 🔧 8. 打包 AAR（确保 JNI 被包含）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android
# 配置 JNI 目录（如果未配置）
if ! grep -q "jniLibs.srcDirs" build.gradle; then
    echo -e "\nsourceSets { main { jniLibs.srcDirs = ['src/main/jniLibs'] } }" >> build.gradle
fi
chmod +x gradlew
./gradlew assembleRelease --no-daemon --verbose --stacktrace \
    -Dorg.gradle.jvmargs="-Xmx2g" \
    -Pandroid.ndkVersion="${ANDROID_NDK_VERSION}" \
    -Pandroid.minSdkVersion="${ANDROID_API_LEVEL}"
cd ../..

# 🔧 9. 收集并验证产物
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

# 打印最终成功信息
echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200（${TARGET}）${NC}"
echo -e "${GREEN}📦 最终产物（release 目录）：${NC}"
echo -e "  - 核心库：libletta_ffi.so（Letta-Lite 核心功能）"
echo -e "  - JNI 库：libletta_jni.so（Android 可调用接口）"
echo -e "  - AAR 包：android-release.aar（即插即用 Android 库）"
echo -e "  - 头文件：letta_lite.h（C 接口说明）"
echo -e "\n${YELLOW}提示：AAR 包可直接导入 Android Studio 使用，无需额外配置依赖！${NC}"
