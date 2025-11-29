#!/usr/bin/env bash
set -euo pipefail

# 硬编码固定路径（含 Rust 标准库路径）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_SYSROOT="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export OPENSSL_INSTALL_DIR=${OPENSSL_DIR:-""}
export SYS_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/sys"
export UNWIND_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/unwind"
export NDK_TOOLCHAIN_BIN="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin"
# 🔧 关键添加：Rust 目标平台标准库路径（GitHub Actions 固定路径）
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/aarch64-linux-android/lib"

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 先检测 rustup 路径
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

# 工具检查
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

# 检查目标平台标准库（已安装直接跳过）
install_target_std() {
    echo -e "\n${YELLOW}=== 检查目标平台标准库（aarch64-linux-android） ===${NC}"
    if rustup target list | grep -q "${TARGET} (installed)"; then
        echo -e "${GREEN}✅ 目标平台标准库已安装${NC}"
        # 验证 Rust 标准库路径是否存在
        if [ -d "$RUST_STD_PATH" ]; then
            echo -e "${GREEN}✅ Rust 标准库路径存在：$RUST_STD_PATH${NC}"
        else
            echo -e "${RED}Error: Rust 标准库路径不存在，可能安装不完整${NC}"
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

# 先检查/安装标准库
install_target_std

# 验证所有路径
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

# 🔧 终极修复：添加 Rust 标准库路径到 RUSTFLAGS，强制编译器找到 core 库
export RUSTFLAGS="\
--sysroot=$NDK_SYSROOT \
-L $RUST_STD_PATH \          # 手动指定目标平台 Rust 标准库（含 core）
-L $SYS_LIB_COPY_PATH \
-L $UNWIND_LIB_COPY_PATH \
-L $OPENSSL_LIB_DIR \
-l libunwind.a \
-l libdl.so \
-l liblog.so \
-l libm.so \
-l libc.so \
-C link-arg=--allow-shlib-undefined \
-C linker=$NDK_TOOLCHAIN_BIN/ld.lld"

# 重新拉取依赖（关联标准库路径）
echo -e "\n${YELLOW}=== 重新拉取所有项目依赖 ===${NC}"
cargo clean -p letta-ffi --target "${TARGET}" || true
cargo fetch --target="${TARGET}" --verbose
echo -e "${GREEN}✅ 项目依赖拉取完成${NC}"

# 交叉编译配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 编译核心库
echo -e "\n${YELLOW}=== 编译核心库（letta-ffi） ===${NC}"
cargo build --workspace --target=${TARGET} --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/target/${TARGET}/mobile/libletta_ffi.so"
mkdir -p "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a"
cp "$CORE_SO" "${PWD}/bindings/android/src/main/jniLibs/arm64-v8a/"
[ ! -f "$CORE_SO" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：$CORE_SO${NC}"

# 生成头文件
echo -e "\n${YELLOW}=== 生成头文件 ===${NC}"
HEADER_FILE=$(find "${PWD}/target" -name "letta_lite.h" | grep -E "${TARGET}/mobile" | head -n 1)
[ -z "${HEADER_FILE}" ] && { echo -e "${RED}Error: 头文件生成失败${NC}"; exit 1; }
mkdir -p ffi/include && cp "$HEADER_FILE" ffi/include/
cp "$HEADER_FILE" bindings/android/src/main/jni/
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
    -L"${UNWIND_LIB_COPY_PATH}" -l libunwind.a \
    -L"${OPENSSL_LIB_DIR}" -lssl -lcrypto -O2
[ ! -f "${JNI_DIR}/libletta_jni.so" ] && { echo -e "${RED}Error: JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功${NC}"

# 打包 AAR
echo -e "\n${YELLOW}=== 打包 AAR ===${NC}"
cd bindings/android && ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g" && cd ../..
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
[ ! -f "${AAR_PATH}" ] && { echo -e "${RED}Error: AAR 打包失败${NC}"; exit 1; }
echo -e "${GREEN}✅ AAR 打包成功${NC}"

# 收集产物
mkdir -p "${PWD}/release"
cp "$CORE_SO" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "$AAR_PATH" "${PWD}/release/"
cp "$HEADER_FILE" "${PWD}/release/"
cp "${PWD}/build.log" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27（终极稳定版）${NC}"
echo -e "${GREEN}📦 产物清单（release 目录）：${NC}"
echo -e "  1. libletta_ffi.so（核心库）"
echo -e "  2. libletta_jni.so（JNI 库）"
echo -e "  3. letta-lite-android.aar（Android 库）"
echo -e "  4. letta_lite.h（C 接口头文件）"
echo -e "  5. build.log（编译日志）"
