#!/usr/bin/env bash
set -euo pipefail

# 第一步：定义所有变量（避免未绑定错误）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 核心路径（原作者规范 + 标准库路径）
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"
export JNI_LIBS_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs"
export FFI_INCLUDE_DIR="${PWD}/ffi/include"
export OPENSSL_DIR="${OPENSSL_DIR:-/home/runner/work/letta-lite/openssl-install}"
# 🔧 关键：手动指定 Rust 标准库路径（之前验证过的有效路径）
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/aarch64-linux-android/lib"
export NDK_HOME="${NDK_HOME:-/usr/local/lib/android/sdk/ndk/27.3.13750724}"

echo -e "\n${YELLOW}=== 融合原作者逻辑 + 标准库路径修复 ===${NC}"

# 工具检查
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

# 安装 cargo-ndk
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}安装 cargo-ndk...${NC}"
    cargo install cargo-ndk --version=3.5.4 --locked
fi

# 🔧 强制验证 + 安装目标平台（双保险）
echo -e "\n${YELLOW}验证目标平台（aarch64-linux-android）...${NC}"
if ! rustup target list | grep -q "${TARGET:-aarch64-linux-android} (installed)"; then
    echo -e "${YELLOW}目标平台未安装，强制安装...${NC}"
    rustup target add aarch64-linux-android --toolchain stable || {
        echo -e "${RED}Error: 目标平台安装失败${NC}"
        exit 1
    }
else
    echo -e "${GREEN}✅ 目标平台已安装${NC}"
fi

# 验证 Rust 标准库路径（关键修复）
if [ ! -d "$RUST_STD_PATH" ]; then
    echo -e "${RED}Error: Rust 标准库路径不存在！${NC}"
    echo "  路径：$RUST_STD_PATH"
    echo "  请检查 rust-std 组件是否安装："
    rustup component list | grep rust-std
    exit 1
fi
echo -e "${GREEN}✅ Rust 标准库路径有效：$RUST_STD_PATH${NC}"

# 配置 OpenSSL + 核心编译参数
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
# 🔧 关键：设置 RUSTFLAGS，传递标准库路径给 cargo ndk
export RUSTFLAGS="\
--sysroot=${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot \
-L $RUST_STD_PATH \
-L ${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/24 \
-lunwind -ldl -llog -lm -lc \
-C link-arg=--allow-shlib-undefined \
-C linker=${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/ld.lld"

# 🔧 原作者 cargo ndk 编译（传递 RUSTFLAGS）
echo -e "\n${YELLOW}=== 编译 Rust 核心库（cargo ndk + 标准库路径） ===${NC}"
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

# 编译 JNI 库
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
    -I"${OPENSSL_INCLUDE_DIR}" \
    -shared -fPIC -o "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" \
    "${ANDROID_PROJECT_DIR}/src/main/jni/letta_jni.c" \
    -L"${JNI_LIBS_DIR}/${arch}" \
    -L"${OPENSSL_LIB_DIR}" \
    -L"$RUST_STD_PATH" \
    -lletta_ffi \
    -lssl -lcrypto \
    -ldl -llog -lm -lc -lunwind
if [ ! -f "${JNI_LIBS_DIR}/${arch}/libletta_jni.so" ]; then
    echo -e "${RED}Error: JNI 库编译失败${NC}"
    exit 1
fi
echo -e "${GREEN}✅ JNI 库生成成功${NC}"

# 打包 AAR（原作者 gradlew 优先）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd "$ANDROID_PROJECT_DIR" || { echo -e "${RED}Error: 进入 Android 项目目录失败${NC}"; exit 1; }
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
else
    echo -e "${YELLOW}无 gradlew，使用系统 gradle 兼容模式${NC}"
    gradle assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" -Dorg.gradle.unsafe.configuration-cache=false
fi
cd - > /dev/null

# 查找 AAR
AAR_PATH="${ANDROID_PROJECT_DIR}/build/outputs/aar/android-release.aar"
if [ ! -f "$AAR_PATH" ]; then
    AAR_FILE=$(find "$ANDROID_PROJECT_DIR" -name "*.aar" | grep -E "release" | head -n 1)
    if [ -z "$AAR_FILE" ]; then
        echo -e "${RED}Error: AAR 打包失败（请补充原作者的 gradlew 和 wrapper 目录）${NC}"
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
ls -l "${PWD}/release/"
