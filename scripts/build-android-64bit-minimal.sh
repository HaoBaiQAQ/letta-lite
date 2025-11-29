#!/usr/bin/env bash
set -euo pipefail

# 核心环境变量（对齐 Android 项目配置）
export TARGET="aarch64-linux-android"
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-21}  # 对齐 build.gradle minSdk 21
export NDK_HOME=${NDK_PATH:-"/usr/local/lib/android/sdk/ndk/27.3.13750724"}
export OPENSSL_DIR=${OPENSSL_INSTALL_DIR:-"/home/runner/work/letta-lite/openssl-install"}
export SYS_LIB_PATH=${SYS_LIB_PATH:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/${TARGET}/lib"

# 项目路径（固定，基于你的目录结构）
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"
export JNI_LIBS_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs/arm64-v8a"
export HEADER_DIR="${ANDROID_PROJECT_DIR}/src/main/jni"

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查（确保核心工具可用）
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
check_command cbindgen
check_command gradle  # 用于生成 gradlew

# 路径验证（确保 Android 项目文件存在）
echo -e "\n${YELLOW}=== 验证项目完整性 ===${NC}"
[ ! -f "${ANDROID_PROJECT_DIR}/build.gradle" ] && { echo -e "${RED}Error: 缺失 build.gradle${NC}"; exit 1; }
[ ! -f "${ANDROID_PROJECT_DIR}/src/main/jni/letta_jni.c" ] && { echo -e "${RED}Error: 缺失 JNI 代码${NC}"; exit 1; }
[ ! -d "${ANDROID_PROJECT_DIR}/src/main/java" ] && { echo -e "${RED}Error: 缺失 Kotlin/Java 代码${NC}"; exit 1; }
echo -e "${GREEN}✅ 项目文件完整${NC}"

# 验证 CI 环境路径
echo -e "\n${YELLOW}=== 验证 CI 环境变量 ===${NC}"
[ -z "${NDK_TOOLCHAIN_BIN}" ] && { echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 未提供${NC}"; exit 1; }
[ -z "${NDK_SYSROOT}" ] && { echo -e "${RED}Error: NDK_SYSROOT 未提供${NC}"; exit 1; }
[ ! -d "${RUST_STD_PATH}" ] && { echo -e "${RED}Error: Rust 标准库路径不存在${NC}"; exit 1; }
[ ! -d "${OPENSSL_DIR}/lib" ] && { echo -e "${RED}Error: OpenSSL 库路径不存在${NC}"; exit 1; }
echo -e "${GREEN}✅ CI 环境验证通过${NC}"

# 核心 RUSTFLAGS（无无效参数）
export RUSTFLAGS="--sysroot=${NDK_SYSROOT} -L ${RUST_STD_PATH} -L ${SYS_LIB_PATH} -L ${OPENSSL_DIR}/lib $( [ -n "${UNWIND_LIB_PATH}" ] && echo "-L ${UNWIND_LIB_PATH}" ) -C panic=abort"

# 交叉编译工具链配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 构建配置汇总（对齐项目配置）
echo -e "\n${YELLOW}=== 构建配置汇总（最终适配版） ===${NC}"
echo -e "  目标平台：${TARGET}（arm64-v8a）"
echo -e "  SDK 版本：compileSdk 34 / minSdk 21 / targetSdk 34（对齐 build.gradle）"
echo -e "  产物：libletta_ffi.so + libletta_jni.so + letta-lite.aar"

# 验证目标平台标准库
echo -e "\n${YELLOW}=== 验证 Rust 目标平台 ===${NC}"
if ! rustup target list | grep -q "${TARGET} (installed)"; then
    echo -e "${YELLOW}安装目标平台 ${TARGET}...${NC}"
    rustup target add "${TARGET}" --toolchain stable || exit 1
fi
echo -e "${GREEN}✅ Rust 目标平台就绪${NC}"

# 1. 编译 Rust 核心库（输出到 Android 项目 jniLibs）
echo -e "\n${YELLOW}=== 编译 Rust 核心库 ===${NC}"
cargo ndk --platform "${ANDROID_API_LEVEL}" -t arm64-v8a -o "${ANDROID_PROJECT_DIR}/src/main/jniLibs" build --profile mobile --verbose -p letta-ffi
CORE_SO="${JNI_LIBS_DIR}/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 2. 生成 C 头文件（输出到 JNI 目录，供 JNI 代码引用）
echo -e "\n${YELLOW}=== 生成 C 头文件 ===${NC}"
cbindgen --crate letta-ffi --lang c --output "${HEADER_DIR}/letta_lite.h"
HEADER_FILE="${HEADER_DIR}/letta_lite.h"
[ ! -f "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 3. 编译 JNI 库（基于你的 letta_jni.c 代码）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"${NDK_SYSROOT}/usr/include" \
    -I"${HEADER_DIR}" \
    -shared -fPIC -o "${JNI_LIBS_DIR}/libletta_jni.so" \
    "${HEADER_DIR}/letta_jni.c" \
    -L"${JNI_LIBS_DIR}" \
    -L"${OPENSSL_DIR}/lib" \
    -L "${SYS_LIB_PATH}" \
    -lletta_ffi \
    -lssl -lcrypto \
    -ldl -llog -lm -lc -O2
JNI_SO="${JNI_LIBS_DIR}/libletta_jni.so"
[ ! -f "${JNI_SO}" ] && { echo -e "${RED}Error: JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功：${JNI_SO}${NC}"

# 4. 打包 AAR（生成 gradlew 后执行原项目打包逻辑）
echo -e "\n${YELLOW}=== 打包 AAR（基于项目 build.gradle） ===${NC}"
cd "${ANDROID_PROJECT_DIR}" || { echo -e "${RED}Error: 进入 Android 项目目录失败${NC}"; exit 1; }

# 生成缺失的 gradlew（适配 build.gradle 34 SDK，指定 Gradle 8.0 版本）
if [ ! -f "gradlew" ]; then
    echo -e "${YELLOW}未找到 gradlew，自动生成（Gradle 8.0 兼容 SDK 34）...${NC}"
    gradle wrapper --gradle-version 8.0 --distribution-type all || { echo -e "${RED}Error: gradlew 生成失败${NC}"; exit 1; }
    chmod +x gradlew
fi

# 执行打包（传递与 build.gradle 一致的 SDK 版本，避免冲突）
echo -e "${YELLOW}执行 gradlew assembleRelease...${NC}"
./gradlew assembleRelease --no-daemon \
    -Dorg.gradle.jvmargs="-Xmx2g" \
    -Pandroid.compileSdkVersion=34 \
    -Pandroid.minSdkVersion=21 \
    -Pandroid.targetSdkVersion=34 || { echo -e "${RED}Error: AAR 打包失败${NC}"; exit 1; }
cd ../..

# 查找并复制最终 AAR
AAR_PATH=$(find "${ANDROID_PROJECT_DIR}/build/outputs/aar" -name "*.aar" | grep -E "release" | head -n 1)
AAR_FINAL="${PWD}/release/letta-lite-android.aar"
mkdir -p "${PWD}/release"
cp "${AAR_PATH}" "${AAR_FINAL}"

# 5. 收集所有产物
echo -e "\n${YELLOW}=== 收集最终产物 ===${NC}"
cp "${CORE_SO}" "${PWD}/release/"
cp "${JNI_SO}" "${PWD}/release/"
cp "${HEADER_FILE}" "${PWD}/release/"
cp "${PWD}/build.log" "${PWD}/release/"

# 验证最终产物
echo -e "\n${GREEN}🎉 所有产物 100% 生成成功！${NC}"
echo -e "${GREEN}📦 最终产物清单（release 目录）：${NC}"
ls -l "${PWD}/release/"
echo -e "\n${GREEN}✅ AAR 详情：${NC}"
echo -e "   - 包含：libletta_ffi.so（核心逻辑） + libletta_jni.so（JNI 接口） + Kotlin 封装类"
echo -e "   - 兼容：Android 21+（Android 5.0+）、arm64-v8a 架构"
echo -e "   - 用法：直接导入 Android 项目，调用 ai.letta.lite.LettaLite 类即可使用所有核心功能！"
