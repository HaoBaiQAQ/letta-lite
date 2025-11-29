#!/usr/bin/env bash
set -euo pipefail

# 核心环境变量（对齐项目配置）
export TARGET="aarch64-linux-android"
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-21}
export NDK_HOME=${NDK_PATH:-"/usr/local/lib/android/sdk/ndk/27.3.13750724"}
export OPENSSL_DIR=${OPENSSL_INSTALL_DIR:-"/home/runner/work/letta-lite/openssl-install"}
export SYS_LIB_PATH=${SYS_LIB_PATH:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/${TARGET}/lib"

# 项目路径
export PROJECT_ROOT="${PWD}"
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"
export JNI_LIBS_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs/arm64-v8a"
export HEADER_DIR="${ANDROID_PROJECT_DIR}/src/main/jni"
export SETTINGS_FILE="${PROJECT_ROOT}/settings.gradle"

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
check_command cbindgen
check_command gradle

# 🔧 第一步：备份原文件 + 用「极简兼容版」settings.gradle（适配所有Gradle版本）
echo -e "\n${YELLOW}=== 配置 settings.gradle（极简兼容版） ===${NC}"
cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.ci.bak" || echo -e "${YELLOW}⚠️  原 settings.gradle 备份失败，可能不存在${NC}"

# 写入「无高版本语法」的极简配置（去掉所有pluginManagement里的plugins，只保留仓库和子模块）
cat > "${SETTINGS_FILE}" << EOF
// 极简兼容版：去掉所有高版本语法，适配 Gradle 4.x+
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "LettaLite"
include ":bindings:android" // 正确的子模块路径
EOF
echo -e "${GREEN}✅ 已写入极简兼容版 settings.gradle（无高版本语法）${NC}"

# 路径验证
echo -e "\n${YELLOW}=== 验证项目完整性 ===${NC}"
[ ! -f "${ANDROID_PROJECT_DIR}/build.gradle" ] && { echo -e "${RED}Error: 缺失 bindings/android/build.gradle${NC}"; exit 1; }
[ ! -f "${HEADER_DIR}/letta_jni.c" ] && { echo -e "${RED}Error: 缺失 JNI 代码${NC}"; exit 1; }
[ ! -d "${ANDROID_PROJECT_DIR}/src/main/java" ] && { echo -e "${RED}Error: 缺失 Kotlin/Java 代码${NC}"; exit 1; }
echo -e "${GREEN}✅ 项目文件完整${NC}"

# 验证 CI 环境路径
echo -e "\n${YELLOW}=== 验证 CI 环境变量 ===${NC}"
[ -z "${NDK_TOOLCHAIN_BIN}" ] && { echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 未提供${NC}"; exit 1; }
[ -z "${NDK_SYSROOT}" ] && { echo -e "${RED}Error: NDK_SYSROOT 未提供${NC}"; exit 1; }
[ ! -d "${RUST_STD_PATH}" ] && { echo -e "${RED}Error: Rust 标准库路径不存在${NC}"; exit 1; }
[ ! -d "${OPENSSL_DIR}/lib" ] && { echo -e "${RED}Error: OpenSSL 库路径不存在${NC}"; exit 1; }
echo -e "${GREEN}✅ CI 环境验证通过${NC}"

# 核心 RUSTFLAGS
export RUSTFLAGS="--sysroot=${NDK_SYSROOT} -L ${RUST_STD_PATH} -L ${SYS_LIB_PATH} -L ${OPENSSL_DIR}/lib $( [ -n "${UNWIND_LIB_PATH}" ] && echo "-L ${UNWIND_LIB_PATH}" ) -C panic=abort"

# 交叉编译工具链配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 1. 编译 Rust 核心库
echo -e "\n${YELLOW}=== 编译 Rust 核心库 ===${NC}"
cargo ndk --platform "${ANDROID_API_LEVEL}" -t arm64-v8a -o "${ANDROID_PROJECT_DIR}/src/main/jniLibs" build --profile mobile --verbose -p letta-ffi
CORE_SO="${JNI_LIBS_DIR}/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 2. 生成 C 头文件
echo -e "\n${YELLOW}=== 生成 C 头文件 ===${NC}"
cbindgen --crate letta-ffi --lang c --output "${HEADER_DIR}/letta_lite.h"
HEADER_FILE="${HEADER_DIR}/letta_lite.h"
[ ! -f "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 3. 编译 JNI 库
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

# 🔧 第二步：生成 gradlew + 打印详细错误栈（按你的要求）
echo -e "\n${YELLOW}=== 生成 gradlew + 打印详细错误日志 ===${NC}"
cd "${ANDROID_PROJECT_DIR}" || { echo -e "${RED}Error: 进入 Android 项目目录失败${NC}"; exit 1; }

# 生成 gradlew 时添加 --stacktrace，打印详细错误（关键！）
echo -e "${YELLOW}正在生成 gradlew（Gradle 7.0，兼容最低版本），并打印详细错误栈...${NC}"
gradle wrapper --gradle-version 7.0 --distribution-type all --stacktrace || {
    echo -e "\n${RED}❌ gradlew 生成失败，详细错误栈如下：${NC}"
    # 手动输出错误日志（确保能看到完整信息）
    cat "${PROJECT_ROOT}/gradle-wrapper-error.log" 2>/dev/null || echo -e "${RED}⚠️  未找到错误日志文件${NC}"
    exit 1
}
chmod +x gradlew

# 执行打包（同样添加 --stacktrace）
echo -e "\n${YELLOW}执行 gradlew assembleRelease + 详细错误栈...${NC}"
./gradlew assembleRelease --no-daemon \
    -Dorg.gradle.jvmargs="-Xmx2g" \
    -Pandroid.compileSdkVersion=34 \
    -Pandroid.minSdkVersion=21 \
    -Pandroid.targetSdkVersion=34 \
    -Pandroid.ndkPath="${NDK_HOME}" \
    --stacktrace || {
        echo -e "\n${RED}❌ 自动打包失败，详细错误栈已打印${NC}"
        exit 1
    }
cd ../..

# 查找并复制 AAR
AAR_PATH=$(find "${ANDROID_PROJECT_DIR}/build/outputs/aar" -name "*.aar" | grep -E "release" | head -n 1)
AAR_FINAL="${PROJECT_ROOT}/release/letta-lite-android.aar"
mkdir -p "${PROJECT_ROOT}/release"
cp "${AAR_PATH}" "${AAR_FINAL}"

# 恢复原 settings.gradle
mv "${SETTINGS_FILE}.ci.bak" "${SETTINGS_FILE}" 2>/dev/null || echo -e "${YELLOW}⚠️  恢复原 settings.gradle 失败${NC}"

# 收集产物
echo -e "\n${YELLOW}=== 收集最终产物 ===${NC}"
cp "${CORE_SO}" "${PROJECT_ROOT}/release/"
cp "${JNI_SO}" "${PROJECT_ROOT}/release/"
cp "${HEADER_FILE}" "${PROJECT_ROOT}/release/"

# 最终验证
echo -e "\n${GREEN}🎉 自动打包 100% 成功！${NC}"
echo -e "${GREEN}📦 产物清单（release 目录）：${NC}"
ls -l "${PROJECT_ROOT}/release/"
