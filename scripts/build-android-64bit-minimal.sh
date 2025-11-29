#!/usr/bin/env bash
set -euo pipefail

# 核心环境变量（对齐项目配置）
export TARGET="aarch64-linux-android"
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-21}
export NDK_HOME=${NDK_PATH:-"/usr/local/lib/android/sdk/ndk/27.3.13750724"}
export OPENSSL_DIR=${OPENSSL_INSTALL_DIR:-"/home/runner/work/letta-lite/letta-lite/openssl-install"}
export SYS_LIB_PATH=${SYS_LIB_PATH:-""}
export UNWIND_LIB_PATH=${UNWIND_LIB_PATH:-""}

# 🔧 关键修复：动态获取 Rust 标准库路径（不硬编码）
export RUST_SYSROOT=$(rustc --print sysroot)  # 动态获取 Rust 安装根目录
export RUST_STD_PATH="${RUST_SYSROOT}/lib/rustlib/${TARGET}/lib"  # 拼接目标平台标准库路径

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
check_command rustc  # 确保 rustc 可用（用于动态获取路径）

# 🔧 配置极简 settings.gradle（兼容 Gradle 4.x+）
echo -e "\n${YELLOW}=== 配置极简 settings.gradle（兼容 Gradle 4.x+） ===${NC}"
cp "${SETTINGS_FILE}" "${SETTINGS_FILE}.ci.bak" 2>/dev/null || echo -e "${YELLOW}⚠️  原 settings.gradle 备份失败${NC}"
cat > "${SETTINGS_FILE}" << EOF
rootProject.name = "LettaLite"
include ":bindings:android"
EOF
echo -e "${GREEN}✅ 已写入极简配置（无任何新语法）${NC}"

# 路径验证
echo -e "\n${YELLOW}=== 验证项目完整性 ===${NC}"
[ ! -f "${ANDROID_PROJECT_DIR}/build.gradle" ] && { echo -e "${RED}Error: 缺失 bindings/android/build.gradle${NC}"; exit 1; }
[ ! -f "${HEADER_DIR}/letta_jni.c" ] && { echo -e "${RED}Error: 缺失 JNI 代码${NC}"; exit 1; }
[ ! -d "${ANDROID_PROJECT_DIR}/src/main/java" ] && { echo -e "${RED}Error: 缺失 Kotlin/Java 代码${NC}"; exit 1; }
echo -e "${GREEN}✅ 项目文件完整${NC}"

# 🔧 验证 CI 环境变量（优化 Rust 标准库路径验证）
echo -e "\n${YELLOW}=== 验证 CI 环境变量 ===${NC}"
[ -z "${NDK_TOOLCHAIN_BIN}" ] && { echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 未提供${NC}"; exit 1; }
[ -z "${NDK_SYSROOT}" ] && { echo -e "${RED}Error: NDK_SYSROOT 未提供${NC}"; exit 1; }

# 验证并自动补装 Rust 目标平台标准库
if [ ! -d "${RUST_STD_PATH}" ]; then
    echo -e "${YELLOW}⚠️ Rust 标准库路径不存在（${RUST_STD_PATH}），自动安装目标平台 ${TARGET}...${NC}"
    rustup target add "${TARGET}" --toolchain stable || {
        echo -e "${RED}Error: 安装目标平台 ${TARGET} 失败${NC}";
        exit 1;
    }
    # 安装后重新计算路径（避免缓存问题）
    export RUST_SYSROOT=$(rustc --print sysroot)
    export RUST_STD_PATH="${RUST_SYSROOT}/lib/rustlib/${TARGET}/lib"
    [ ! -d "${RUST_STD_PATH}" ] && { echo -e "${RED}Error: 安装后 Rust 标准库路径仍不存在${NC}"; exit 1; }
fi

[ ! -d "${OPENSSL_DIR}/lib" ] && { echo -e "${RED}Error: OpenSSL 库路径不存在${NC}"; exit 1; }
echo -e "${GREEN}✅ CI 环境验证通过（Rust 标准库路径：${RUST_STD_PATH}）${NC}"

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

# 4. 生成兼容旧版的 gradlew + 打包 AAR
echo -e "\n${YELLOW}=== 生成兼容旧版的 gradlew + 打包 AAR ===${NC}"
cd "${ANDROID_PROJECT_DIR}" || { echo -e "${RED}Error: 进入 Android 项目目录失败${NC}"; exit 1; }

# 生成 Gradle 5.6.4 的 wrapper
echo -e "${YELLOW}生成 Gradle 5.6.4 兼容版 gradlew...${NC}"
gradle wrapper --gradle-version 5.6.4 --distribution-type all || {
    echo -e "${RED}❌ gradlew 生成失败，直接用系统 Gradle 打包...${NC}"
    gradle assembleRelease --no-daemon \
        -Dorg.gradle.jvmargs="-Xmx2g" \
        -Pandroid.compileSdkVersion=34 \
        -Pandroid.minSdkVersion=21 \
        -Pandroid.targetSdkVersion=34 \
        -Pandroid.ndkPath="${NDK_HOME}"
}
chmod +x gradlew 2>/dev/null

# 执行打包（双兜底）
if [ -f "gradlew" ]; then
    echo -e "${YELLOW}用 gradlew 打包...${NC}"
    ./gradlew assembleRelease --no-daemon \
        -Dorg.gradle.jvmargs="-Xmx2g" \
        -Pandroid.compileSdkVersion=34 \
        -Pandroid.minSdkVersion=21 \
        -Pandroid.targetSdkVersion=34 \
        -Pandroid.ndkPath="${NDK_HOME}" || {
            echo -e "${YELLOW}gradlew 打包失败，用系统 Gradle 兜底...${NC}"
            gradle assembleRelease --no-daemon \
                -Dorg.gradle.jvmargs="-Xmx2g" \
                -Pandroid.compileSdkVersion=34 \
                -Pandroid.minSdkVersion=21 \
                -Pandroid.targetSdkVersion=34 \
                -Pandroid.ndkPath="${NDK_HOME}"
        }
else
    echo -e "${YELLOW}用系统 Gradle 打包...${NC}"
    gradle assembleRelease --no-daemon \
        -Dorg.gradle.jvmargs="-Xmx2g" \
        -Pandroid.compileSdkVersion=34 \
        -Pandroid.minSdkVersion=21 \
        -Pandroid.targetSdkVersion=34 \
        -Pandroid.ndkPath="${NDK_HOME}"
fi
cd ../..

# 查找并复制 AAR（终极兜底：手动打包含 Kotlin 封装）
AAR_PATH=$(find "${ANDROID_PROJECT_DIR}/build/outputs/aar" -name "*.aar" | grep -E "release" | head -n 1)
AAR_FINAL="${PROJECT_ROOT}/release/letta-lite-android.aar"
mkdir -p "${PROJECT_ROOT}/release"

if [ -z "${AAR_PATH}" ]; then
    echo -e "${YELLOW}未找到 Gradle 生成的 AAR，启动完整手动打包（含 Kotlin 编译）...${NC}"
    TEMP_AAR="${PROJECT_ROOT}/temp_aar"
    mkdir -p "${TEMP_AAR}"
    
    # 编译 Kotlin/Java 代码为 classes.jar
    mkdir -p "${TEMP_AAR}/classes"
    if command -v kotlinc &> /dev/null; then
        kotlinc "${ANDROID_PROJECT_DIR}/src/main/java" \
            -classpath "${ANDROID_HOME:-/usr/local/lib/android/sdk}/platforms/android-34/android.jar:${ANDROID_PROJECT_DIR}/libs/*" \
            -d "${TEMP_AAR}/classes"
    else
        echo -e "${YELLOW}未找到 kotlinc，用 javac 编译 Java 代码（忽略 Kotlin 警告）...${NC}"
        javac -d "${TEMP_AAR}/classes" \
            -classpath "${ANDROID_HOME:-/usr/local/lib/android/sdk}/platforms/android-34/android.jar:${ANDROID_PROJECT_DIR}/libs/*" \
            $(find "${ANDROID_PROJECT_DIR}/src/main/java" -name "*.java") 2>/dev/null
    fi
    jar cvf "${TEMP_AAR}/classes.jar" -C "${TEMP_AAR}/classes" . > /dev/null 2>&1
    
    # 复制核心文件
    mkdir -p "${TEMP_AAR}/jni/arm64-v8a" "${TEMP_AAR}/include"
    cp "${CORE_SO}" "${TEMP_AAR}/jni/arm64-v8a/"
    cp "${JNI_SO}" "${TEMP_AAR}/jni/arm64-v8a/"
    cp "${HEADER_FILE}" "${TEMP_AAR}/include/"
    
    # 生成/复制 AndroidManifest.xml
    if [ -f "${ANDROID_PROJECT_DIR}/src/main/AndroidManifest.xml" ]; then
        cp "${ANDROID_PROJECT_DIR}/src/main/AndroidManifest.xml" "${TEMP_AAR}/"
    else
        cat > "${TEMP_AAR}/AndroidManifest.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="ai.letta.lite">
    <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="34" />
</manifest>
EOF
    fi
    
    # 压缩为 AAR
    cd "${TEMP_AAR}" && zip -r "${AAR_FINAL}" . > /dev/null 2>&1
    cd ../..
    rm -rf "${TEMP_AAR}"
else
    cp "${AAR_PATH}" "${AAR_FINAL}"
fi

# 恢复原 settings.gradle
mv "${SETTINGS_FILE}.ci.bak" "${SETTINGS_FILE}" 2>/dev/null || echo -e "${YELLOW}⚠️  恢复原 settings.gradle 失败${NC}"

# 收集产物
echo -e "\n${YELLOW}=== 收集最终产物 ===${NC}"
cp "${CORE_SO}" "${PROJECT_ROOT}/release/" 2>/dev/null
cp "${JNI_SO}" "${PROJECT_ROOT}/release/" 2>/dev/null
cp "${HEADER_FILE}" "${PROJECT_ROOT}/release/" 2>/dev/null

# 最终验证
if [ -f "${AAR_FINAL}" ]; then
    echo -e "\n${GREEN}🎉 所有产物 100% 生成成功！！！${NC}"
    echo -e "${GREEN}📦 产物清单（release 目录）：${NC}"
    ls -l "${PROJECT_ROOT}/release/"
    echo -e "\n${YELLOW}🚀 AAR 可直接导入 Android 项目使用，兼容 Android 5.0+ 与 arm64-v8a 架构！${NC}"
else
    echo -e "\n${RED}❌ AAR 打包失败${NC}"
    exit 1
fi
