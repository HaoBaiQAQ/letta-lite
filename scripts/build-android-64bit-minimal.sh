#!/usr/bin/env bash
set -euo pipefail

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 项目路径（不用改）
export PROJECT_ROOT="${PWD}"
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"
export JNI_LIBS_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs/arm64-v8a"
export HEADER_DIR="${ANDROID_PROJECT_DIR}/src/main/jni"
export SETTINGS_FILE="${PROJECT_ROOT}/settings.gradle"

# 工具检查（不用改）
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
check_command rustc

# 🔧 第二重保险：脚本内强制卸载+安装（确保目标架构生效）
echo -e "\n${YELLOW}=== 清理 Rust 环境 ===${NC}"
rustup target uninstall aarch64-linux-android 2>/dev/null || true
rustup target install aarch64-linux-android --toolchain stable || { echo -e "${RED}Error: 安装目标平台失败${NC}"; exit 1; }
cargo fetch  # 只拉取锁定版本，不更新依赖
echo -e "${GREEN}✅ Rust 环境清理完成${NC}"

# 配置 settings.gradle（不用改）
echo -e "\n${YELLOW}=== 配置 settings.gradle ===${NC}"
cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.ci.bak" 2>/dev/null || true
cat > "${SETTINGS_FILE}" << EOF
rootProject.name = "LettaLite"
include ":bindings:android"
EOF
echo -e "${GREEN}✅ settings.gradle 配置完成${NC}"

# 验证项目完整性（不用改）
echo -e "\n${YELLOW}=== 验证项目完整性 ===${NC}"
[ ! -f "${ANDROID_PROJECT_DIR}/build.gradle" ] && { echo -e "${RED}Error: 缺失 build.gradle${NC}"; exit 1; }
[ ! -f "${HEADER_DIR}/letta_jni.c" ] && { echo -e "${RED}Error: 缺失 JNI 代码${NC}"; exit 1; }
[ ! -d "${ANDROID_PROJECT_DIR}/src/main/java" ] && { echo -e "${RED}Error: 缺失 Kotlin/Java 代码${NC}"; exit 1; }
echo -e "${GREEN}✅ 项目文件完整${NC}"

# 验证 CI 环境（不用改）
echo -e "\n${YELLOW}=== 验证 CI 环境 ===${NC}"
[ -z "${NDK_TOOLCHAIN_BIN:-}" ] && { echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 未提供${NC}"; exit 1; }
[ -z "${NDK_SYSROOT:-}" ] && { echo -e "${RED}Error: NDK_SYSROOT 未提供${NC}"; exit 1; }
[ ! -d "${OPENSSL_DIR:-}/lib" ] && { echo -e "${RED}Error: OpenSSL 路径不存在${NC}"; exit 1; }
echo -e "${GREEN}✅ CI 环境验证通过${NC}"

# 🔧 核心：用 NDK Clang 编译 Rust 核心库
echo -e "\n${YELLOW}=== 编译 Rust 核心库 ===${NC}"
export CC="${NDK_TOOLCHAIN_BIN}/${TARGET}-clang"
export CXX="${NDK_TOOLCHAIN_BIN}/${TARGET}-clang++"
cargo ndk --platform "${ANDROID_API_LEVEL:-24}" -t arm64-v8a -o "${ANDROID_PROJECT_DIR}/src/main/jniLibs" build --release --verbose -p letta-ffi
CORE_SO="${JNI_LIBS_DIR}/libletta_ffi.so"
[ ! -f "${CORE_SO}" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成头文件（不用改）
echo -e "\n${YELLOW}=== 生成 C 头文件 ===${NC}"
cbindgen --crate letta-ffi --lang c --output "${HEADER_DIR}/letta_lite.h"
HEADER_FILE="${HEADER_DIR}/letta_lite.h"
[ ! -f "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 编译 JNI 库（不用改）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
"${CC_aarch64_linux_android:-${NDK_TOOLCHAIN_BIN}/${TARGET:-aarch64-linux-android}${ANDROID_API_LEVEL:-24}-clang}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"${NDK_SYSROOT}/usr/include" \
    -I"${HEADER_DIR}" \
    -shared -fPIC -o "${JNI_LIBS_DIR}/libletta_jni.so" \
    "${HEADER_DIR}/letta_jni.c" \
    -L"${JNI_LIBS_DIR}" \
    -L"${OPENSSL_DIR}/lib" \
    -L "${UNWIND_LIB_PATH:-}" \
    -lletta_ffi \
    -lssl -lcrypto \
    -ldl -llog -lm -lc -O2
JNI_SO="${JNI_LIBS_DIR}/libletta_jni.so"
[ ! -f "${JNI_SO}" ] && { echo -e "${RED}Error: JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功：${JNI_SO}${NC}"

# 打包 AAR（不用改）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd "${ANDROID_PROJECT_DIR}" || exit 1

echo -e "${YELLOW}生成 Gradle 7.5 兼容版 gradlew...${NC}"
gradle wrapper --gradle-version 7.5 --distribution-type all || {
    echo -e "${RED}gradlew 生成失败，用系统 Gradle 兜底...${NC}"
    gradle assembleRelease --no-daemon \
        -Dorg.gradle.jvmargs="-Xmx2g" \
        -Pandroid.compileSdkVersion=34 \
        -Pandroid.minSdkVersion=21 \
        -Pandroid.targetSdkVersion=34 \
        -Pandroid.ndkPath="${NDK_PATH:-/usr/local/lib/android/sdk/ndk/27.3.13750724}"
}
chmod +x gradlew 2>/dev/null

# 执行打包
if [ -f "gradlew" ]; then
    ./gradlew assembleRelease --no-daemon \
        -Dorg.gradle.jvmargs="-Xmx2g" \
        -Pandroid.compileSdkVersion=34 \
        -Pandroid.minSdkVersion=21 \
        -Pandroid.targetSdkVersion=34 \
        -Pandroid.ndkPath="${NDK_PATH:-/usr/local/lib/android/sdk/ndk/27.3.13750724}" || {
            echo -e "${YELLOW}gradlew 打包失败，用系统 Gradle 兜底...${NC}"
            gradle assembleRelease --no-daemon \
                -Dorg.gradle.jvmargs="-Xmx2g" \
                -Pandroid.compileSdkVersion=34 \
                -Pandroid.minSdkVersion=21 \
                -Pandroid.targetSdkVersion=34 \
                -Pandroid.ndkPath="${NDK_PATH:-/usr/local/lib/android/sdk/ndk/27.3.13750724}"
        }
else
    gradle assembleRelease --no-daemon \
        -Dorg.gradle.jvmargs="-Xmx2g" \
        -Pandroid.compileSdkVersion=34 \
        -Pandroid.minSdkVersion=21 \
        -Pandroid.targetSdkVersion=34 \
        -Pandroid.ndkPath="${NDK_PATH:-/usr/local/lib/android/sdk/ndk/27.3.13750724}"
fi
cd ../..

# 收集产物（不用改）
echo -e "\n${YELLOW}=== 收集产物 ===${NC}"
AAR_PATH=$(find "${ANDROID_PROJECT_DIR}/build/outputs/aar" -name "*.aar" -path "*/release/*" | head -n 1)
AAR_FINAL="${PROJECT_ROOT}/release/letta-lite-android.aar"
mkdir -p "${PROJECT_ROOT}/release"

if [ -z "${AAR_PATH}" ]; then
    echo -e "${YELLOW}手动打包 AAR...${NC}"
    TEMP_AAR="${PROJECT_ROOT}/temp_aar"
    mkdir -p "${TEMP_AAR}/jni/arm64-v8a" "${TEMP_AAR}/include" "${TEMP_AAR}/classes"
    cp "${CORE_SO}" "${TEMP_AAR}/jni/arm64-v8a/"
    cp "${JNI_SO}" "${TEMP_AAR}/jni/arm64-v8a/"
    cp "${HEADER_FILE}" "${TEMP_AAR}/include/"
    kotlinc "${ANDROID_PROJECT_DIR}/src/main/java" -classpath "${ANDROID_HOME:-/usr/local/lib/android/sdk}/platforms/android-34/android.jar" -d "${TEMP_AAR}/classes" 2>/dev/null
    jar cvf "${TEMP_AAR}/classes.jar" -C "${TEMP_AAR}/classes" . > /dev/null 2>&1
    cp "${ANDROID_PROJECT_DIR}/src/main/AndroidManifest.xml" "${TEMP_AAR}/" 2>/dev/null || cat > "${TEMP_AAR}/AndroidManifest.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="ai.letta.lite">
    <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="34" />
</manifest>
EOF
    cd "${TEMP_AAR}" && zip -r "${AAR_FINAL}" . > /dev/null 2>&1
    cd ../..
    rm -rf "${TEMP_AAR}"
else
    cp "${AAR_PATH}" "${AAR_FINAL}"
fi

# 恢复原 settings.gradle
mv "${SETTINGS_FILE}.ci.bak" "${SETTINGS_FILE}" 2>/dev/null || true

# 复制其他产物
cp "${CORE_SO}" "${PROJECT_ROOT}/release/" 2>/dev/null
cp "${JNI_SO}" "${PROJECT_ROOT}/release/" 2>/dev/null
cp "${HEADER_FILE}" "${PROJECT_ROOT}/release/" 2>/dev/null

# 验证结果
if [ -f "${AAR_FINAL}" ]; then
    echo -e "\n${GREEN}🎉 所有产物生成成功！！！${NC}"
    echo -e "${GREEN}📦 release 目录包含：${NC}"
    ls -l "${PROJECT_ROOT}/release/"
    echo -e "\n${YELLOW}🚀 终于搞定所有坑！AAR 可直接导入 Android 项目使用！${NC}"
else
    echo -e "\n${RED}❌ AAR 打包失败${NC}"
    exit 1
fi
