#!/usr/bin/env bash
set -euo pipefail

# 颜色配置（确保红字报错清晰）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 项目路径
export PROJECT_ROOT="${PWD}"
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"
export JNI_LIBS_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs/arm64-v8a"
export HEADER_DIR="${ANDROID_PROJECT_DIR}/src/main/jni"
export SETTINGS_FILE="${PROJECT_ROOT}/settings.gradle"

# 工具检查（报错直接红字输出）
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}❌ Error: 缺失工具 $1${NC}"
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

# 验证核心库（从工作流传递的路径）
echo -e "\n${YELLOW}=== 验证 Rust 核心库 ===${NC}"
if [ -z "${CORE_LIB_PATH:-}" ] || [ ! -f "${CORE_LIB_PATH}/libcore.rlib" ]; then
  echo -e "${RED}❌ 核心库（core）路径无效或文件缺失！路径：${CORE_LIB_PATH}${NC}"
  exit 1
fi
echo -e "${GREEN}✅ 核心库路径有效：${CORE_LIB_PATH}/libcore.rlib${NC}"

# 配置 settings.gradle
echo -e "\n${YELLOW}=== 配置 settings.gradle ===${NC}"
cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.ci.bak" 2>/dev/null || true
cat > "${SETTINGS_FILE}" << EOF
rootProject.name = "LettaLite"
include ":bindings:android"
EOF
echo -e "${GREEN}✅ settings.gradle 配置完成${NC}"

# 验证项目完整性（红字报错）
echo -e "\n${YELLOW}=== 验证项目完整性 ===${NC}"
if [ ! -f "${ANDROID_PROJECT_DIR}/build.gradle" ]; then
  echo -e "${RED}❌ Error: 缺失 build.gradle${NC}"
  exit 1
fi
if [ ! -f "${HEADER_DIR}/letta_jni.c" ]; then
  echo -e "${RED}❌ Error: 缺失 JNI 代码${NC}"
  exit 1
fi
if [ ! -d "${ANDROID_PROJECT_DIR}/src/main/java" ]; then
  echo -e "${RED}❌ Error: 缺失 Kotlin/Java 代码${NC}"
  exit 1
fi
echo -e "${GREEN}✅ 项目文件完整${NC}"

# 验证 CI 环境（红字报错）
echo -e "\n${YELLOW}=== 验证 CI 环境 ===${NC}"
if [ -z "${NDK_TOOLCHAIN_BIN:-}" ]; then
  echo -e "${RED}❌ Error: NDK_TOOLCHAIN_BIN 未提供${NC}"
  exit 1
fi
if [ -z "${NDK_SYSROOT:-}" ]; then
  echo -e "${RED}❌ Error: NDK_SYSROOT 未提供${NC}"
  exit 1
fi
if [ -z "${OPENSSL_INSTALL_DIR:-}" ] || [ ! -d "${OPENSSL_INSTALL_DIR}/lib" ]; then
  echo -e "${RED}❌ Error: OpenSSL 路径不存在${NC}"
  exit 1
fi
echo -e "${GREEN}✅ CI 环境验证通过${NC}"

# 编译 Rust 核心库（红字报错+详细日志）
echo -e "\n${YELLOW}=== 编译 Rust 核心库 ===${NC}"
export CC="${NDK_TOOLCHAIN_BIN}/${TARGET}-clang"
export CXX="${NDK_TOOLCHAIN_BIN}/${TARGET}-clang++"
export RUSTFLAGS="--sysroot=${NDK_SYSROOT} -L ${UNWIND_LIB_PATH} -L ${OPENSSL_INSTALL_DIR}/lib -C link-arg=--target=aarch64-linux-android24 -L ${CORE_LIB_PATH}"

# 执行编译，失败则输出详细错误
if ! cargo ndk --platform "${ANDROID_API_LEVEL:-24}" -t arm64-v8a -o "${ANDROID_PROJECT_DIR}/src/main/jniLibs" build --release --verbose -p letta-ffi \
    --config "dependencies.libc.features = [\"android\"]" \
    --config "dependencies.libc.default-features = false"; then
  echo -e "${RED}❌ Rust 核心库编译失败！${NC}"
  tail -n 50 build.log
  exit 1
fi

CORE_SO="${JNI_LIBS_DIR}/libletta_ffi.so"
if [ ! -f "${CORE_SO}" ]; then
  echo -e "${RED}❌ Error: 核心库编译失败，未生成 ${CORE_SO}${NC}"
  exit 1
fi
echo -e "${GREEN}✅ 核心库生成成功：${CORE_SO}${NC}"

# 生成头文件（红字报错）
echo -e "\n${YELLOW}=== 生成 C 头文件 ===${NC}"
if ! cbindgen --crate letta-ffi --lang c --output "${HEADER_DIR}/letta_lite.h"; then
  echo -e "${RED}❌ 头文件生成失败！${NC}"
  exit 1
fi
HEADER_FILE="${HEADER_DIR}/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
  echo -e "${RED}❌ Error: 头文件生成失败，未找到 ${HEADER_FILE}${NC}"
  exit 1
fi
echo -e "${GREEN}✅ 头文件生成成功：${HEADER_FILE}${NC}"

# 编译 JNI 库（红字报错）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_COMPILER="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL:-24}-clang"
if ! "${JNI_COMPILER}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"${NDK_SYSROOT}/usr/include" \
    -I"${HEADER_DIR}" \
    -I"${OPENSSL_INSTALL_DIR}/include" \
    -shared -fPIC -o "${JNI_LIBS_DIR}/libletta_jni.so" \
    "${HEADER_DIR}/letta_jni.c" \
    -L"${JNI_LIBS_DIR}" \
    -L"${OPENSSL_INSTALL_DIR}/lib" \
    -L "${UNWIND_LIB_PATH:-}" \
    -lletta_ffi \
    -lssl -lcrypto \
    -ldl -llog -lm -lc -O2; then
  echo -e "${RED}❌ JNI 库编译失败！${NC}"
  exit 1
fi

JNI_SO="${JNI_LIBS_DIR}/libletta_jni.so"
if [ ! -f "${JNI_SO}" ]; then
  echo -e "${RED}❌ Error: JNI 库编译失败，未生成 ${JNI_SO}${NC}"
  exit 1
fi
echo -e "${GREEN}✅ JNI 库生成成功：${JNI_SO}${NC}"

# 打包 AAR（红字报错）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd "${ANDROID_PROJECT_DIR}" || {
  echo -e "${RED}❌ 进入 Android 项目目录失败！${NC}"
  exit 1
}

if [ ! -f "gradlew" ]; then
  echo -e "${YELLOW}生成 Gradle 7.5 兼容版 gradlew...${NC}"
  if ! gradle wrapper --gradle-version 7.5 --distribution-type all; then
    echo -e "${RED}❌ gradlew 生成失败！${NC}"
    exit 1
  fi
  chmod +x gradlew
fi

if ! ./gradlew assembleRelease --no-daemon \
    -Dorg.gradle.jvmargs="-Xmx2g" \
    -Pandroid.compileSdkVersion=34 \
    -Pandroid.minSdkVersion=21 \
    -Pandroid.targetSdkVersion=34 \
    -Pandroid.ndkPath="${NDK_PATH:-}"; then
  echo -e "${RED}❌ AAR 打包失败！${NC}"
  tail -n 50 ./build/logs/gradle.log 2>/dev/null
  exit 1
fi
cd ../..

# 收集产物（完整收集）
echo -e "\n${YELLOW}=== 收集产物 ===${NC}"
AAR_PATH=$(find "${ANDROID_PROJECT_DIR}/build/outputs/aar" -name "*.aar" -path "*/release/*" | head -n 1)
AAR_FINAL="${PROJECT_ROOT}/release/letta-lite-android.aar"
mkdir -p "${PROJECT_ROOT}/release"

if [ -z "${AAR_PATH}" ]; then
  echo -e "${RED}❌ Error: 未找到 AAR 产物${NC}"
  # 手动打包兜底（如果之前步骤都成功）
  echo -e "${YELLOW}尝试手动打包 AAR...${NC}"
  TEMP_AAR="${PROJECT_ROOT}/temp_aar"
  mkdir -p "${TEMP_AAR}/jni/arm64-v8a" "${TEMP_AAR}/include" "${TEMP_AAR}/classes"
  cp "${CORE_SO}" "${TEMP_AAR}/jni/arm64-v8a/" 2>/dev/null || true
  cp "${JNI_SO}" "${TEMP_AAR}/jni/arm64-v8a/" 2>/dev/null || true
  cp "${HEADER_FILE}" "${TEMP_AAR}/include/" 2>/dev/null || true
  kotlinc "${ANDROID_PROJECT_DIR}/src/main/java" -classpath "${ANDROID_HOME:-/usr/local/lib/android/sdk}/platforms/android-34/android.jar" -d "${TEMP_AAR}/classes" 2>/dev/null || true
  jar cvf "${TEMP_AAR}/classes.jar" -C "${TEMP_AAR}/classes" . > /dev/null 2>&1 || true
  cp "${ANDROID_PROJECT_DIR}/src/main/AndroidManifest.xml" "${TEMP_AAR}/" 2>/dev/null || cat > "${TEMP_AAR}/AndroidManifest.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="ai.letta.lite">
    <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="34" />
</manifest>
EOF
  cd "${TEMP_AAR}" && zip -r "${AAR_FINAL}" . > /dev/null 2>&1 || {
    echo -e "${RED}❌ 手动打包 AAR 也失败！${NC}"
    cd ../..
    rm -rf "${TEMP_AAR}"
    exit 1
  }
  cd ../..
  rm -rf "${TEMP_AAR}"
  echo -e "${YELLOW}⚠️  手动打包 AAR 成功：${AAR_FINAL}${NC}"
else
  cp "${AAR_PATH}" "${AAR_FINAL}"
  echo -e "${GREEN}✅ AAR 打包成功：${AAR_FINAL}${NC}"
fi

# 恢复原 settings.gradle
mv "${SETTINGS_FILE}.ci.bak" "${SETTINGS_FILE}" 2>/dev/null || true

# 复制其他产物
cp "${CORE_SO}" "${PROJECT_ROOT}/release/" 2>/dev/null || true
cp "${JNI_SO}" "${PROJECT_ROOT}/release/" 2>/dev/null || true
cp "${HEADER_FILE}" "${PROJECT_ROOT}/release/" 2>/dev/null || true

# 最终验证结果（红字报错）
if [ ! -f "${AAR_FINAL}" ]; then
  echo -e "\n${RED}❌ 最终产物收集失败！未找到 AAR 文件${NC}"
  exit 1
fi

echo -e "\n${GREEN}🎉 所有产物生成成功！！！${NC}"
echo -e "${GREEN}📦 release 目录包含：${NC}"
ls -l "${PROJECT_ROOT}/release/"
echo -e "\n${YELLOW}🚀 AAR 可直接导入 Android 项目使用！${NC}"
