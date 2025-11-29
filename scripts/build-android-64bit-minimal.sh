#!/usr/bin/env bash
set -euo pipefail

# 硬编码固定路径（和工作流一致）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_SYSROOT="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export OPENSSL_INSTALL_DIR=${OPENSSL_DIR:-""}
export SYS_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/sys"
export UNWIND_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/unwind"
export NDK_TOOLCHAIN_BIN="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin"

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 工具检查（优先确保 rustup 可用）
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

# 🔧 核心修复：强制安装目标平台标准库（含 core crate），重试+权限+ verbose 日志
install_target_std() {
    echo -e "\n${YELLOW}=== 强制安装目标平台标准库（aarch64-linux-android） ===${NC}"
    # 指定 stable 工具链，避免歧义，加 sudo 确保权限，--verbose 查看安装日志
    sudo rustup target add --toolchain stable --verbose "${TARGET}" || {
        echo -e "${YELLOW}⚠️ 第一次安装失败，重试...${NC}"
        sudo rustup target add --toolchain stable --verbose "${TARGET}" || {
            echo -e "${RED}Error: 目标平台标准库安装失败${NC}"
            exit 1
        }
    }
    # 验证安装结果（必须显示 "installed"）
    if rustup target list | grep -q "${TARGET} (installed)"; then
        echo -e "${GREEN}✅ 目标平台标准库安装成功${NC}"
    else
        echo -e "${RED}Error: 目标平台显示未安装，实际安装失败${NC}"
        # 打印 rustup 状态，方便排查
        rustup target list
        rustup show
        exit 1
    fi
}

# 先安装标准库，再验证其他路径
install_target_std

# 验证所有路径是否存在
if [ ! -d "$SYS_LIB_COPY_PATH" ] || [ ! -d "$NDK_SYSROOT" ]; then
    echo -e "${RED}Error: 系统库路径或 NDK 路径不存在${NC}"
    exit 1
fi

# OpenSSL 配置
export OPENSSL_LIB_DIR="${OPENSSL_INSTALL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_INSTALL_DIR}/include"
echo -e "${GREEN}✅ 配置完成：${NC}"
echo -e "  - 系统库路径：$SYS_LIB_COPY_PATH"
echo -e "  - NDK SYSROOT：$NDK_SYSROOT"
echo -e "  - 链接器：$NDK_TOOLCHAIN_BIN/ld.lld"

# 🔧 重新拉取所有项目依赖（关联已安装的标准库）
echo -e "\n${YELLOW}=== 重新拉取所有项目依赖 ===${NC}"
# 清除旧依赖缓存，确保重新关联标准库
cargo clean -p letta-ffi --target "${TARGET}" || true
# 拉取依赖时指定目标平台，确保依赖适配
cargo fetch --target="${TARGET}" --verbose
echo -e "${GREEN}✅ 项目依赖拉取完成${NC}"

# 交叉编译配置
export CC_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/${TARGET}${ANDROID_API_LEVEL}-clang"
export AR_aarch64_linux_android="${NDK_TOOLCHAIN_BIN}/llvm-ar"
export PKG_CONFIG_ALLOW_CROSS=1

# 精简 RUSTFLAGS（和 Cargo config 一致）
export RUSTFLAGS="--sysroot=$NDK_SYSROOT -L $SYS_LIB_COPY_PATH -L $UNWIND_LIB_COPY_PATH -L $OPENSSL_LIB_DIR -l libunwind.a -l libdl.so -l liblog.so -l libm.so -l libc.so -C link-arg=--allow-shlib-undefined -C linker=$NDK_TOOLCHAIN_BIN/ld.lld"

# 编译核心库（带 --verbose 查看标准库引用情况）
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

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27（最终稳定版）${NC}"
echo -e "${GREEN}📦 产物清单（release 目录）：${NC}"
echo -e "  1. libletta_ffi.so（核心库）"
echo -e "  2. libletta_jni.so（JNI 库）"
echo -e "  3. letta-lite-android.aar（Android 库）"
echo -e "  4. letta_lite.h（C 接口头文件）"
echo -e "  5. build.log（编译日志）"
