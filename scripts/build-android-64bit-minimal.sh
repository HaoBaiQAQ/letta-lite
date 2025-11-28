#!/usr/bin/env bash
set -euo pipefail

# 🔧 强制仅编译64位架构，继承工作流中的环境变量
export CARGO_TARGET=aarch64-linux-android
export ANDROID_ABI=arm64-v8a
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}  # 从工作流继承 API 级别
export NDK_TOOLCHAIN_BIN=${NDK_TOOLCHAIN_BIN:-""}  # 从工作流继承 NDK 编译器目录
export NDK_SYSROOT=${NDK_SYSROOT:-""}              # 从工作流继承 sysroot

echo "Building Letta Lite for Android (64-bit only) - 最终修复版..."

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

# 🔧 关键修复：给 openssl-sys 传递交叉编译器路径（核心！）
if [ -z "${NDK_TOOLCHAIN_BIN}" ] || [ -z "${NDK_SYSROOT}" ]; then
    echo -e "${RED}Error: NDK_TOOLCHAIN_BIN 或 NDK_SYSROOT 未从工作流传递${NC}"
    exit 1
fi
# 明确告诉 cargo：aarch64 架构的 C 编译器路径（openssl-sys 需要）
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${CARGO_TARGET}${ANDROID_API_LEVEL}-clang"
# 明确告诉 cargo：aarch64 架构的归档工具路径
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
# 验证编译器是否存在
if [ ! -f "${CC_aarch64_linux_android}" ]; then
    echo -e "${RED}Error: 交叉编译器不存在：${CC_aarch64_linux_android}${NC}"
    echo "NDK 工具链目录内容："
    ls -l "${NDK_TOOLCHAIN_BIN}" | grep "aarch64-linux-android"
    exit 1
fi
echo -e "${GREEN}✅ 交叉编译器配置完成：${CC_aarch64_linux_android}${NC}"

# 🔧 继承工作流中的 OpenSSL 配置（已编译好的静态库）
if [ -z "${OPENSSL_DIR:-}" ]; then
    echo -e "${RED}Error: OPENSSL_DIR 未从工作流传递（需指向编译好的 OpenSSL 目录）${NC}"
    exit 1
fi
export OPENSSL_INCLUDE_DIR="${OPENSSL_DIR}/include"
export OPENSSL_LIB_DIR="${OPENSSL_DIR}/lib"
export PKG_CONFIG_ALLOW_CROSS=1  # 允许跨平台 pkg-config 查找
echo -e "${GREEN}✅ OpenSSL 配置完成：${OPENSSL_DIR}${NC}"

# 原作者cargo-ndk安装（原作者本地已装，CI 补装）
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk (原作者本地已配置)${NC}"
    cargo install cargo-ndk --version=3.5.4 --locked
fi

# 原作者NDK路径检查（原作者本地已配置 NDK 环境变量）
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set (原作者本地已配置)${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-${ANDROID_NDK_HOME:-}}"

# 🔧 显式安装 aarch64 目标（原作者本地已安装）
echo "Adding Android 64-bit target (aarch64-linux-android)..."
ACTIVE_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
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

# 🔧 步骤2：修复 feature 报错 - 直接触发 build.rs 生成头文件（原作者原版逻辑）
# 关键：去掉 --features cbindgen（Cargo.toml 没定义这个 feature）
# 执行 cargo build 会自动运行 build.rs，生成头文件到 ffi/include/letta_lite.h
echo "Generating C header (原作者 build.rs 自动触发)..."
cargo build -p letta-ffi \
    --target="${CARGO_TARGET}" \
    --profile mobile \
    --verbose
# 验证头文件（根据 build.rs 配置，输出路径是 ffi/include/letta_lite.h）
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "${HEADER_FILE}" ]; then
    echo -e "${YELLOW}Searching for generated header file...${NC}"
    HEADER_FILE=$(find "${GITHUB_WORKSPACE}" -name "letta_lite.h" | grep -v "target/debug" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件未找到（build.rs 执行失败）${NC}"
        exit 1
    fi
fi
# 复制头文件到 JNI 目录（原作者本地操作）
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

# 🔧 验证最终产物（原作者本地会手动检查）
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
SO_PATH="bindings/android/src/main/jniLibs/arm64-v8a/libletta_jni.so"
if [ -f "$AAR_PATH" ] && [ -f "$SO_PATH" ]; then
    echo -e "${GREEN}🎉 编译成功！所有产物生成完毕！${NC}"
    echo "📦 AAR 路径: ${AAR_PATH}"
    echo "📦 JNI SO 路径: ${SO_PATH}"
else
    echo -e "${RED}❌ 产物生成失败${NC}"
    echo "AAR 存在？$(test -f "$AAR_PATH" && echo "是" || echo "否")"
    echo "SO 存在？$(test -f "$SO_PATH" && echo "是" || echo "否")"
    exit 1
fi
