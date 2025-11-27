#!/usr/bin/env bash
set -euo pipefail

# 🔧 强制仅编译64位架构，彻底禁用32位，避免冲突
export CARGO_TARGET=aarch64-linux-android
export ANDROID_ABI=arm64-v8a

echo "Building Letta Lite for Android (64-bit only)..."

# 原作者颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 原作者工具检查
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}
check_command rustup
check_command cargo

# 🔧 关键修复1：显式获取当前活跃的 Rust 工具链（避免工具链不匹配）
ACTIVE_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
echo -e "✅ Active Rust toolchain: ${ACTIVE_TOOLCHAIN}"

# 原作者cargo-ndk安装（用原作者方式，不指定版本避免冲突）
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# 原作者NDK路径检查
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-${ANDROID_NDK_HOME:-}}"

# 🔧 关键修复2：显式指定工具链安装目标，验证路径
echo "Adding Android 64-bit target (aarch64-linux-android) to ${ACTIVE_TOOLCHAIN}..."
# 显式指定工具链安装，避免安装到其他工具链
rustup target add aarch64-linux-android --toolchain "${ACTIVE_TOOLCHAIN}"
# 验证目标是否安装成功（更精准的检查）
if ! rustup target list --toolchain "${ACTIVE_TOOLCHAIN}" | grep -q "aarch64-linux-android (installed)"; then
    echo -e "${RED}Error: aarch64-linux-android target not installed for ${ACTIVE_TOOLCHAIN}${NC}"
    echo "Available targets:"
    rustup target list --toolchain "${ACTIVE_TOOLCHAIN}"
    exit 1
fi
# 手动计算 RUSTLIB 路径（核心！告诉cargo build核心库在哪）
RUSTLIB_PATH="$HOME/.rustup/toolchains/${ACTIVE_TOOLCHAIN}/lib/rustlib/${CARGO_TARGET}"
if [ ! -d "${RUSTLIB_PATH}" ]; then
    echo -e "${RED}Error: RUSTLIB path not found: ${RUSTLIB_PATH}${NC}"
    exit 1
fi
export RUSTLIB="${RUSTLIB_PATH}"
echo -e "${GREEN}✅ RUSTLIB set to: ${RUSTLIB_PATH}${NC}"

# 🔧 仅编译64位，加--verbose便于排错（原作者核心编译逻辑不变）
echo "Building Letta FFI (64-bit)..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile --verbose  # 原作者的--profile mobile，正确

# 🔧 终极修复：用 NDK 的 libunwind_llvm.so 替代 libunwind.so
echo "Generating C header (aarch64 architecture)..."
# 1. 编译器（CC）：编译源代码
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET_ARCH}${ANDROID_API_LEVEL}-clang"
# 2. 归档工具（AR）：打包静态库
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
# 3. 链接器（LD）：强制指定+sysroot路径
LINKER_PATH="${NDK_TOOLCHAIN_BIN}/ld.lld"
# 4. 补充2个关键路径：API版本路径 + 无API版本路径（NDK核心库在这里）
NDK_LIB_API_PATH="${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API_LEVEL}"
NDK_LIB_CORE_PATH="${NDK_SYSROOT}/usr/lib/aarch64-linux-android"  # 无API版本，包含unwind_llvm
# 5. 关键参数：-lunwind_llvm 替代 -lunwind，同时保留允许未定义符号
export RUSTFLAGS="--sysroot=${NDK_SYSROOT} -L${NDK_SYSROOT}/usr/lib -L${NDK_LIB_API_PATH} -L${NDK_LIB_CORE_PATH} -L${RUSTLIB_PATH}/lib -C link-arg=-lunwind_llvm -C link-arg=--allow-shlib-undefined"
# 执行cargo build，生成头文件
echo "Running cargo build with RUSTFLAGS: ${RUSTFLAGS}"
cargo build -p letta-ffi \
    --target=aarch64-linux-android \
    --profile mobile \
    --config "target.aarch64-linux-android.linker=\"${LINKER_PATH}\"" \
    --verbose
# 复制头文件（保留容错逻辑）
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || {
    echo -e "${YELLOW}Warning: 头文件未找到，尝试查找生成路径...${NC}"
    HEAD_FILE=$(find "${GITHUB_WORKSPACE}/target" -name "letta_lite.h" -type f | head -n 1)
    if [ -n "$HEAD_FILE" ]; then
        cp "$HEAD_FILE" bindings/android/src/main/jni/
        echo -e "${GREEN}✅ 从$HEAD_FILE找到并复制头文件${NC}"
    else
        echo -e "${RED}❌ 头文件生成失败，终止编译${NC}"
        exit 1
    fi
}

# 🔧 仅编译64位JNI（原作者编译逻辑不变）
echo "Compiling JNI wrapper (64-bit)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=21
    
    echo "  Building JNI for $arch..."
    "${NDK_HOME}"/toolchains/llvm/prebuilt/*/bin/clang \
        --target="${triple}${api_level}" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"${NDK_HOME}/sysroot/usr/include" \
        -Iffi/include \
        -shared \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi
}

if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"  # 仅保留64位
else
    echo -e "${YELLOW}Warning: JNI wrapper not found, skipping JNI compilation${NC}"
    exit 1  # JNI缺失会导致AAR无用，直接报错
fi

# 原作者AAR构建逻辑（现在不会被打断，能正常执行）
echo "Building Android AAR..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    echo "Running gradlew assembleRelease..."
    ./gradlew assembleRelease --verbose --stacktrace
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ gradlew assembleRelease failed${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}gradlew not found, using system gradle${NC}"
    gradle assembleRelease --verbose --stacktrace
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ gradle assembleRelease failed${NC}"
        exit 1
    fi
fi
cd ../..

# 🔧 验证产物（确保SO和AAR都生成）
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
SO_PATH="bindings/android/src/main/jniLibs/arm64-v8a/libletta_jni.so"
if [ -f "$AAR_PATH" ] && [ -f "$SO_PATH" ]; then
    echo -e "${GREEN}✅ Build successful!${NC}"
    echo "AAR: $AAR_PATH"
    echo "SO: $SO_PATH"
else
    echo -e "${RED}❌ Build failed: 产物缺失${NC}"
    echo "AAR exists? $(test -f "$AAR_PATH" && echo "Yes" || echo "No")"
    echo "SO exists? $(test -f "$SO_PATH" && echo "Yes" || echo "No")"
    exit 1
fi
