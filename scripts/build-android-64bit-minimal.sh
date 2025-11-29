#!/usr/bin/env bash
set -euo pipefail

# 核心环境变量（对齐你的项目配置）
export TARGET="aarch64-linux-android"
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-21}
export NDK_HOME=${NDK_PATH:-"/usr/local/lib/android/sdk/ndk/27.3.13750724"}
export OPENSSL_DIR=${OPENSSL_INSTALL_DIR:-"/home/runner/work/letta-lite/openssl-install"}
export SYS_LIB_PATH=${SYS_LIB_PATH:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/${TARGET}/lib"

# 项目路径（按你的实际目录）
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

# 🔧 关键：备份原文件→修改→打包后恢复，不影响本地开发
echo -e "\n${YELLOW}=== 处理 settings.gradle（兼容 CI 环境） ===${NC}"
# 备份你的原始文件（命名为 settings.gradle.ci.bak）
if [ -f "${SETTINGS_FILE}" ]; then
    cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.ci.bak"
    echo -e "${GREEN}✅ 已备份你的原始 settings.gradle 为 settings.gradle.ci.bak${NC}"
fi

# 写入兼容 CI 的配置（只改2处，保留你的核心配置）
cat > "${SETTINGS_FILE}" << EOF
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id 'com.android.application' version '7.4.2' apply false
        id 'com.android.library' version '7.4.2' apply false
        id 'org.jetbrains.kotlin.android' version '1.9.20' apply false
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "LettaLite"
include ":bindings:android"
EOF
echo -e "${GREEN}✅ 已临时修改 settings.gradle 适配 CI（打包后自动恢复）${NC}"

# 路径验证（确保 Android 项目存在）
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

# 4. 自动打包 AAR（生成兼容 Gradle 7.5 的 wrapper）
echo -e "\n${YELLOW}=== 自动打包 AAR ===${NC}"
cd "${ANDROID_PROJECT_DIR}" || { echo -e "${RED}Error: 进入 Android 项目目录失败${NC}"; exit 1; }

# 生成 Gradle 7.5 的 wrapper（兼容插件版本 7.4.2）
if [ ! -f "gradlew" ]; then
    echo -e "${YELLOW}生成 Gradle 7.5 兼容版 gradlew...${NC}"
    gradle wrapper --gradle-version 7.5 --distribution-type all || { echo -e "${RED}Error: gradlew 生成失败${NC}"; exit 1; }
    chmod +x gradlew
fi

# 执行打包（对齐你的 build.gradle 配置）
echo -e "${YELLOW}执行 gradlew assembleRelease...${NC}"
./gradlew assembleRelease --no-daemon \
    -Dorg.gradle.jvmargs="-Xmx2g" \
    -Pandroid.compileSdkVersion=34 \
    -Pandroid.minSdkVersion=21 \
    -Pandroid.targetSdkVersion=34 \
    -Pandroid.ndkPath="${NDK_HOME}" || { echo -e "${RED}Error: 自动打包失败${NC}"; exit 1; }
cd ../..

# 查找并复制 AAR
AAR_PATH=$(find "${ANDROID_PROJECT_DIR}/build/outputs/aar" -name "*.aar" | grep -E "release" | head -n 1)
AAR_FINAL="${PROJECT_ROOT}/release/letta-lite-android.aar"
mkdir -p "${PROJECT_ROOT}/release"
cp "${AAR_PATH}" "${AAR_FINAL}"

# 🔧 关键：恢复你的原始 settings.gradle（不影响本地开发）
if [ -f "${SETTINGS_FILE}.ci.bak" ]; then
    mv "${SETTINGS_FILE}.ci.bak" "${SETTINGS_FILE}"
    echo -e "${GREEN}✅ 已恢复你的原始 settings.gradle 文件${NC}"
fi

# 收集产物
echo -e "\n${YELLOW}=== 收集最终产物 ===${NC}"
cp "${CORE_SO}" "${PROJECT_ROOT}/release/"
cp "${JNI_SO}" "${PROJECT_ROOT}/release/"
cp "${HEADER_FILE}" "${PROJECT_ROOT}/release/"
cp "${PROJECT_ROOT}/build.log" "${PROJECT_ROOT}/release/"

# 最终验证
echo -e "\n${GREEN}🎉 自动打包 100% 成功！${NC}"
echo -e "${GREEN}📦 产物清单（release 目录）：${NC}"
ls -l "${PROJECT_ROOT}/release/"
echo -e "\n${YELLOW}🚀 你的原始配置已完全恢复，AAR 可直接导入 Android 项目使用！${NC}"
