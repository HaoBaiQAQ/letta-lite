#!/usr/bin/env bash
set -euo pipefail

# 硬编码固定路径（所有路径已验证有效）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_SYSROOT="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export OPENSSL_INSTALL_DIR=${OPENSSL_DIR:-""}
export SYS_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/sys"
export UNWIND_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/unwind"
export NDK_TOOLCHAIN_BIN="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin"
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/aarch64-linux-android/lib"

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检测 rustup 路径（确保命令可用）
find_rustup() {
    echo -e "\n${YELLOW}=== 检测 rustup 路径 ===${NC}"
    if command -v rustup &> /dev/null; then
        RUSTUP_PATH=$(command -v rustup)
        echo -e "${GREEN}✅ 找到 rustup：$RUSTUP_PATH${NC}"
        return 0
    else
        POSSIBLE_PATHS=(
            "/home/runner/.rustup/bin/rustup"
            "/usr/local/cargo/bin/rustup"
            "/home/runner/.cargo/bin/rustup"
        )
        for path in "${POSSIBLE_PATHS[@]}"; do
            if [ -x "$path" ]; then
                export PATH="$path:$PATH"
                echo -e "${GREEN}✅ 手动找到 rustup：$path${NC}"
                return 0
            fi
        done
        echo -e "${RED}Error: 找不到 rustup 命令${NC}"
        exit 1
    fi
}

# 工具检查（含 cbindgen，头文件生成必需）
find_rustup
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: 缺失工具 $1${NC}"
        exit 1
    fi
}
check_command cargo
check_command cargo-ndk
check_command clang
check_command cbindgen

# 检查目标平台标准库（已安装直接跳过）
install_target_std() {
    echo -e "\n${YELLOW}=== 检查目标平台标准库（aarch64-linux-android） ===${NC}"
    if rustup target list | grep -q "${TARGET} (installed)"; then
        echo -e "${GREEN}✅ 目标平台标准库已安装${NC}"
        if [ -d "$RUST_STD_PATH" ]; then
            echo -e "${GREEN}✅ Rust 标准库路径存在：$RUST_STD_PATH${NC}"
        else
            echo -e "${RED}Error: Rust 标准库路径不存在${NC}"
            rustup component list | grep rust-std
            exit 1
        fi
        return 0
    fi
    echo -e "${YELLOW}⚠️ 目标平台未安装，开始安装...${NC}"
    rustup target add --toolchain stable "${TARGET}" || {
        echo -e "${YELLOW}⚠️ 第一次安装失败，重试...${NC}"
        rustup target add --toolchain stable "${TARGET}" || {
            echo -e "${RED}Error: 目标平台标准库安装失败${NC}"
            exit 1
        }
    }
}

# 执行标准库检查
install_target_std

# 验证关键路径
if [ ! -d "$SYS_LIB_COPY_PATH" ] || [ ! -d "$NDK_SYSROOT" ] || [ ! -d "$RUST_STD_PATH" ]; then
    echo -e "${RED}Error: 部分关键路径不存在${NC}"
    exit 1
fi

# OpenSSL 配置
export OPENSSL_LIB_DIR="${OPENSSL_INSTALL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_INSTALL_DIR}/include"
echo -e "${GREEN}✅ 配置完成：${NC}"
echo -e "  - Rust 标准库路径：$RUST_STD_PATH"
echo -e "  - 系统库路径：$SYS_LIB_COPY_PATH"
echo -e "  - NDK SYSROOT：$NDK_SYSROOT"

# 简化库名格式（已验证无解析错误）
export RUSTFLAGS="--sysroot=$NDK_SYSROOT -L $RUST_STD_PATH -L $SYS_LIB_COPY_PATH -L $UNWIND_LIB_COPY_PATH -L $OPENSSL_LIB_DIR -lunwind -ldl -llog -lm -lc -C link-arg=--allow-shlib-undefined -C linker=$NDK_TOOLCHAIN_BIN/ld.lld"

# 重新拉取依赖
echo -e "\n${YELLOW}=== 重新拉取所有项目依赖 ===${NC}"
cargo clean -p letta-ffi --target "${TARGET}" || true
cargo fetch --target="${TARGET}" --verbose
echo -e "${GREEN}✅ 项目依赖拉取完成${NC}"

# 交叉编译配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译 Rust 核心库（已成功，保留）
echo -e "\n${YELLOW}=== 编译核心库（letta-ffi） ===${NC}"
cargo build --workspace --target=${TARGET} --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/target/${TARGET}/mobile/libletta_ffi.so"
mkdir -p "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
cp "$CORE_SO" "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/"
[ ! -f "$CORE_SO" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：$CORE_SO${NC}"

# 🔧 修复：去掉 --config 参数，用 cbindgen 默认配置生成头文件
echo -e "\n${YELLOW}=== 生成头文件（cbindgen 默认配置） ===${NC}"
mkdir -p ffi/include bindings/android/src/main/jni
# 直接生成，不依赖配置文件（默认配置足够 JNI 使用）
cbindgen --crate letta-ffi --output ffi/include/letta_lite.h
HEADER_FILE="ffi/include/letta_lite.h"
if [ ! -f "$HEADER_FILE" ]; then
    echo -e "${YELLOW}⚠️ cbindgen 生成失败，搜索自动生成的头文件...${NC}"
    HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
    if [ -z "${HEADER_FILE}" ]; then
        echo -e "${RED}Error: 头文件生成失败${NC}"
        ls -l "${PWD}/target/${TARGET}/mobile/"
        exit 1
    fi
    cp "$HEADER_FILE" ffi/include/
    cp "$HEADER_FILE" bindings/android/src/main/jni/
else
    cp "$HEADER_FILE" bindings/android/src/main/jni/
fi
echo -e "${GREEN}✅ 头文件生成成功：$HEADER_FILE${NC}"

# 编译 JNI 库
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"ffi/include" \
    -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" \
    "bindings/android/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" -lletta_ffi \
    -L"${SYS_LIB_COPY_PATH}" -ldl -llog -lm -lc \
    -L"${UNWIND_LIB_COPY_PATH}" -lunwind \
    -L"${OPENSSL_LIB_DIR}" -lssl -lcrypto -O2
[ ! -f "${JNI_DIR}/libletta_jni.so" ] && { echo -e "${RED}Error: JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功${NC}"

# 打包 AAR（含日志输出和搜索逻辑）
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android && ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" --info 2>&1 | tee ../../android-build.log && cd ../..
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ ! -f "$AAR_PATH" ]; then
    echo -e "${YELLOW}⚠️ 搜索 release 目录下的 AAR 文件...${NC}"
    AAR_FILE=$(find "${PWD}/bindings/android" -name "*.aar" | grep -E "release" | head -n 1)
    if [ -z "$AAR_FILE" ]; then
        echo -e "${RED}Error: AAR 打包失败${NC}"
        cat ../../android-build.log
        exit 1
    fi
    AAR_PATH="$AAR_FILE"
fi
echo -e "${GREEN}✅ AAR 打包成功：$AAR_PATH${NC}"

# 收集产物
mkdir -p "${PWD}/release"
cp "$CORE_SO" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "$AAR_PATH" "${PWD}/release/letta-lite-android.aar"
cp "$HEADER_FILE" "${PWD}/release/"
cp "${PWD}/build.log" "${PWD}/release/"
cp "${PWD}/android-build.log" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27${NC}"
echo -e "${GREEN}📦 release 目录产物：${NC}"
ls -l "${PWD}/release/"
