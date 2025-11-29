#!/usr/bin/env bash
set -euo pipefail

# 🔧 第一步：先定义所有变量（避免未绑定错误）
# 颜色变量（必须放在最前面）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 核心路径变量（复用原作者规范）
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"
export JNI_LIBS_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs"
export FFI_INCLUDE_DIR="${PWD}/ffi/include"
export OPENSSL_DIR="${OPENSSL_DIR:-/home/runner/work/letta-lite/openssl-install}"  # 兼容环境变量

echo -e "\n${YELLOW}=== 复用原作者核心逻辑构建 Letta-Lite Android 产物 ===${NC}"

# 工具检查（复用原作者精简逻辑）
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: 缺失工具 $1${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo
check_command clang
check_command cbindgen

# 安装 cargo-ndk（原作者核心依赖）
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}安装 cargo-ndk（原作者核心工具）...${NC}"
    cargo install cargo-ndk --version=3.5.4 --locked
fi

# 检查 NDK 环境（复用原作者自动识别）
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${YELLOW}未设置 NDK 环境变量，自动识别 GitHub Actions 路径...${NC}"
    export NDK_HOME="/usr/local/lib/android/sdk/ndk/27.3.13750724"
    if [ ! -d "$NDK_HOME" ]; then
        echo -e "${RED}Error: 未找到 NDK，请设置 NDK_HOME${NC}"
        exit 1
    fi
fi

# 安装目标平台
echo -e "\n${YELLOW}安装目标平台（aarch64-linux-android）...${NC}"
rustup target add aarch64-linux-android || true

# 🔧 复用原作者 cargo ndk 编译核心库（自动处理 NDK 路径）
echo -e "\n${YELLOW}=== 编译 Rust 核心库（cargo ndk 驱动） ===${NC}"
# 传递 OPENSSL 配置给 cargo ndk
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
cargo ndk \
    -t arm64-v8a \
    -o "$JNI_LIBS_DIR" \
    build -p letta-ffi --profile mobile
CORE_SO="${JNI_LIBS_DIR}/arm64-v8a/libletta_ffi.so"
if [ ! -f "$CORE_SO" ]; then
    echo -e "${RED}Error: 核心库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 核心库生成成功：$CORE_SO${NC}"

# 生成纯 C 头文件
echo -e "\n${YELLOW}=== 生成 C 头文件 ===${NC}"
mkdir -p "$FFI_INCLUDE_DIR" "${ANDROID_PROJECT_DIR}/src/main/jni"
cbindgen --crate letta-ffi --lang c --output "${FFI_INCLUDE_DIR}/letta_lite.h"
cp "${FFI_INCLUDE_DIR}/letta_lite.h" "${ANDROID_PROJECT_DIR}/src/main/jni/"
echo -e "${GREEN}✅ 头文件生成成功${NC}"

# 🔧 复用原作者 JNI 编译逻辑
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
local arch="arm64-v8a"
local triple="aarch64-linux-android"
local api_level=24
"${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" \
    --target="${triple}${api_level}" \
    --sysroot="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"$FFI_INCLUDE_DIR" \
    -I"${OPENSSL_INCLUDE_DIR}" \  # 添加 OpenSSL 头文件路径
    -shared -fPIC -o "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" \
    "${ANDROID_PROJECT_DIR}/src/main/jni/letta_jni.c" \
    -L"${JNI_LIBS_DIR}/${arch}" \
    -L"${OPENSSL_LIB_DIR}" \  # 添加 OpenSSL 库路径
    -lletta_ffi \
    -lssl -lcrypto \  # 链接 OpenSSL 库
    -ldl -llog -lm -lc
if [ ! -f "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" ]; then
    echo -e "${RED}Error: JNI 库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ JNI 库生成成功${NC}"

# 🔧 复用原作者 gradlew 优先打包逻辑
echo -e "\n${YELLOW}=== 打包 AAR（gradlew 优先） ===${NC}"
cd "$ANDROID_PROJECT_DIR" || { echo -e "${RED}Error: 进入 Android 项目目录失败${NC}"; exit 1; }

if [ -f "gradlew" ]; then
    echo -e "${YELLOW}使用项目内 gradlew 打包...${NC}"
    chmod +x gradlew
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
else
    echo -e "${YELLOW}无 gradlew，使用兼容模式打包...${NC}"
    gradle assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" -Dorg.gradle.unsafe.configuration-cache=false
fi
cd - > /dev/null

# 查找 AAR 产物
AAR_PATH="${ANDROID_PROJECT_DIR}/build/outputs/aar/android-release.aar"
if [ ! -f "$AAR_PATH" ]; then
    echo -e "${YELLOW}⚠️ 搜索 release 版本 AAR...${NC}"
    AAR_FILE=$(find "$ANDROID_PROJECT_DIR" -name "*.aar" | grep -E "release" | head -n 1)
    if [ -z "$AAR_FILE" ]; then
        echo -e "${RED}Error: AAR 打包失败（建议补充原作者的 gradlew 和 wrapper 目录）${NC}"
        exit 1
    fi
    AAR_PATH="$AAR_FILE"
fi

# 收集产物
mkdir -p "${PWD}/release"
cp "$CORE_SO" "${PWD}/release/"
cp "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" "${PWD}/release/"
cp "$AAR_PATH" "${PWD}/release/letta-lite-android.aar"
cp "${FFI_INCLUDE_DIR}/letta_lite.h" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27${NC}"
echo -e "${GREEN}📦 release 目录产物：${NC}"
ls -l "${PWD}/release/"
