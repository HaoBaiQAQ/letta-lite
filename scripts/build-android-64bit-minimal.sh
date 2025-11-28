#!/usr/bin/env bash
set -euo pipefail

# 🔧 强制仅编译64位架构，彻底禁用32位，避免冲突
export CARGO_TARGET=aarch64-linux-android
export ANDROID_ABI=arm64-v8a

echo "Building Letta Lite for Android (64-bit only) - 复刻原作者思路+兼容低版本Rust..."

# 原作者颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 原作者工具检查（原作者本地必装的工具）
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed (原作者本地已配置)${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo

# 🔧 显式获取当前活跃的 Rust 工具链+版本（兼容低版本）
ACTIVE_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
RUST_VERSION=$(rustc --version | awk '{print $2}')
echo -e "✅ Active Rust toolchain: ${ACTIVE_TOOLCHAIN} (version: ${RUST_VERSION})"

# 原作者cargo-ndk安装（原作者本地已装，CI 补装）
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk (原作者本地已配置)${NC}"
    cargo install cargo-ndk
fi

# 原作者NDK路径检查（原作者本地已配置 NDK 环境变量）
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set (原作者本地已配置)${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-${ANDROID_NDK_HOME:-}}"

# 🔧 安装原作者 build.rs 依赖的 cbindgen（原作者本地已装）
if ! command -v cbindgen &> /dev/null; then
    echo -e "${YELLOW}Installing cbindgen (原作者 build.rs 依赖)${NC}"
    cargo install cbindgen
fi

# 🔧 显式安装 aarch64 目标（原作者本地已安装）
echo "Adding Android 64-bit target (aarch64-linux-android)..."
rustup target add aarch64-linux-android --toolchain "${ACTIVE_TOOLCHAIN}"
if ! rustup target list --toolchain "${ACTIVE_TOOLCHAIN}" | grep -q "aarch64-linux-android (installed)"; then
    echo -e "${RED}Error: aarch64-linux-android target not installed${NC}"
    exit 1
fi

# 🔧 步骤1：原作者核心流程 - 用 cargo ndk 编译核心库（已验证成功）
echo "Building Letta FFI core library (原作者 cargo ndk 流程)..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose
echo -e "${GREEN}✅ 核心库 libletta_ffi.so 生成成功！${NC}"

# 🔧 步骤2：兼容低版本Rust - 用 cargo check 触发 build.rs 生成头文件
# cargo check 作用：语法检查 + 执行 build.rs（不编译二进制，不链接依赖）
echo "Generating C header via build.rs (原作者思路+兼容低版本Rust)..."
cargo check -p letta-ffi \
    --target=aarch64-linux-android \
    --profile mobile \
    --verbose  # 输出详细日志，确认 build.rs 执行
echo -e "${GREEN}✅ build.rs 执行完成，头文件生成成功！${NC}"

# 🔧 验证头文件是否生成到原作者指定路径（原作者 build.rs 默认输出到 ffi/include/）
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    # 兼容原作者可能的输出路径（比如 target 目录、JNI 目录）
    echo -e "${YELLOW}Searching for generated header file...${NC}"
    HEADER_FILE=$(find "${GITHUB_WORKSPACE}" -name "letta_lite.h" | grep -v "target/debug" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件未找到（请检查原作者 build.rs 中的输出路径）${NC}"
        exit 1
    fi
fi
# 复制头文件到 JNI 目录（原作者本地手动复制或 build.rs 自动输出）
cp "${HEADER_FILE}" bindings/android/src/main/jni/
echo -e "${GREEN}✅ 头文件已复制到 JNI 目录：bindings/android/src/main/jni/letta_lite.h${NC}"
echo -e "📌 头文件原始路径：${HEADER_FILE}"

# 🔧 步骤3：原作者 JNI 编译流程（原作者本地用 NDK 编译）
echo "Compiling JNI wrapper (原作者 NDK 编译流程)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=21  # 原作者本地默认 API 级别
    
    echo "  Building JNI for ${arch}..."
    "${NDK_HOME}"/toolchains/llvm/prebuilt/*/bin/clang \
        --target="${triple}${api_level}" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"${NDK_HOME}/sysroot/usr/include" \
        -Ibindings/android/src/main/jni/ \
        -shared \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi
}

if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
    echo -e "${GREEN}✅ JNI 库 libletta_jni.so 生成成功！${NC}"
else
    echo -e "${RED}Error: JNI 源码 letta_jni.c 未找到（原作者本地已存在）${NC}"
    exit 1
fi

# 🔧 步骤4：原作者 AAR 打包流程（原作者本地用 Gradle 打包）
echo "Building Android AAR (原作者 Gradle 流程)..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew assembleRelease --verbose --stacktrace
else
    gradle assembleRelease --verbose --stacktrace
fi
cd ../..
echo -e "${GREEN}✅ AAR 包生成成功！${NC}"

# 🔧 验证最终产物（原作者本地会手动检查）
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
SO_PATH="bindings/android/src/main/jniLibs/arm64-v8a/libletta_jni.so"
if [ -f "$AAR_PATH" ] && [ -f "$SO_PATH" ]; then
    echo -e "${GREEN}🎉 原作者流程复刻成功！所有产物生成完毕！${NC}"
    echo "📦 AAR 路径: ${AAR_PATH}"
    echo "📦 JNI SO 路径: ${SO_PATH}"
else
    echo -e "${RED}❌ 产物生成失败（原作者本地可能修改了输出路径）${NC}"
    exit 1
fi
