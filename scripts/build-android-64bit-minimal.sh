#!/usr/bin/env bash
set -euo pipefail

# 硬编码固定路径（已验证有效）
export TARGET=${TARGET:-aarch64-linux-android}
export ANDROID_API_LEVEL=${ANDROID_API_LEVEL:-24}
export NDK_SYSROOT="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export OPENSSL_INSTALL_DIR=${OPENSSL_DIR:-""}
export SYS_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/sys"
export UNWIND_LIB_COPY_PATH="/home/runner/work/letta-lite/letta-lite/dependencies/lib/unwind"
export NDK_TOOLCHAIN_BIN="/usr/local/lib/android/sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin"
export RUST_STD_PATH="/home/runner/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/aarch64-linux-android/lib"
export ANDROID_PROJECT_DIR="${PWD}/bindings/android"  # 明确Android项目路径

# 颜色配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检测 rustup 路径
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

# 工具检查（参考原作者，补充gradle检查）
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
check_command gradle  # 原作者脚本依赖系统gradle，确保已安装

# 检查目标平台标准库
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

# 验证关键路径（含Android项目路径）
if [ ! -d "$SYS_LIB_COPY_PATH" ] || [ ! -d "$NDK_SYSROOT" ] || [ ! -d "$RUST_STD_PATH" ] || [ ! -d "$ANDROID_PROJECT_DIR" ]; then
    echo -e "${RED}Error: 部分关键路径不存在（Android项目路径：$ANDROID_PROJECT_DIR）${NC}"
    exit 1
fi

# OpenSSL 配置
export OPENSSL_LIB_DIR="${OPENSSL_INSTALL_DIR}/lib"
export OPENSSL_INCLUDE_DIR="${OPENSSL_INSTALL_DIR}/include"
echo -e "${GREEN}✅ 配置完成：${NC}"
echo -e "  - Rust 标准库路径：$RUST_STD_PATH"
echo -e "  - 系统库路径：$SYS_LIB_COPY_PATH"
echo -e "  - Android项目路径：$ANDROID_PROJECT_DIR"

# 简化库名格式（已验证无错误）
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

# 编译 Rust 核心库（参考原作者，输出到JNI目录）
echo -e "\n${YELLOW}=== 编译核心库（letta-ffi） ===${NC}"
cargo build --workspace --target="${TARGET}" --profile mobile --verbose -p letta-ffi
CORE_SO="${PWD}/target/${TARGET}/mobile/libletta_ffi.so"
# 复制到Android项目的JNI目录（原作者脚本的输出路径）
mkdir -p "${ANDROID_PROJECT_DIR}/src/main/jniLibs/arm64-v8a"
cp "$CORE_SO" "${ANDROID_PROJECT_DIR}/src/main/jniLibs/arm64-v8a/"
[ ! -f "$CORE_SO" ] && { echo -e "${RED}Error: 核心库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ 核心库生成成功：$CORE_SO${NC}"

# 生成纯C头文件（参考原作者，简化逻辑）
echo -e "\n${YELLOW}=== 生成头文件（纯C风格） ===${NC}"
mkdir -p ffi/include "${ANDROID_PROJECT_DIR}/src/main/jni"
cbindgen --crate letta-ffi --lang c --output ffi/include/letta_lite.h
HEADER_FILE="ffi/include/letta_lite.h"
cp "$HEADER_FILE" "${ANDROID_PROJECT_DIR}/src/main/jni/"
echo -e "${GREEN}✅ 头文件生成成功：$HEADER_FILE${NC}"

# 编译 JNI 库（参考原作者，简化编译命令）
echo -e "\n${YELLOW}=== 编译 JNI 库 ===${NC}"
JNI_DIR="${ANDROID_PROJECT_DIR}/src/main/jniLibs/arm64-v8a"
"${CC_aarch64_linux_android}" \
    --sysroot="${NDK_SYSROOT}" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
    -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
    -I"ffi/include" \
    -shared -fPIC -o "${JNI_DIR}/libletta_jni.so" \
    "${ANDROID_PROJECT_DIR}/src/main/jni/letta_jni.c" \
    -L"${JNI_DIR}" -lletta_ffi \
    -L"${SYS_LIB_COPY_PATH}" -ldl -llog -lm -lc \
    -L"${UNWIND_LIB_COPY_PATH}" -lunwind \
    -L"${OPENSSL_LIB_DIR}" -lssl -lcrypto -O2
[ ! -f "${JNI_DIR}/libletta_jni.so" ] && { echo -e "${RED}Error: JNI 库编译失败${NC}"; exit 1; }
echo -e "${GREEN}✅ JNI 库生成成功${NC}"

# 🔧 参考原作者脚本修复AAR打包：优先用gradlew，没有就用系统gradle
echo -e "\n${YELLOW}=== 打包 AAR（参考原作者逻辑） ===${NC}"
cd "$ANDROID_PROJECT_DIR" || { echo -e "${RED}Error: 进入Android项目目录失败${NC}"; exit 1; }
# 原作者逻辑：先试项目内gradlew，没有就用系统gradle
if [ -f "gradlew" ]; then
    echo -e "${YELLOW}使用项目内 gradlew 打包...${NC}"
    chmod +x gradlew  # 确保有执行权限
    ./gradlew assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
else
    echo -e "${YELLOW}使用系统 gradle 打包...${NC}"
    gradle assembleRelease --no-daemon -Dorg.gradle.jvmargs="-Xmx2g"
fi
cd - > /dev/null  # 回到原目录，隐藏输出

# 查找AAR（参考原作者输出路径）
AAR_PATH="${ANDROID_PROJECT_DIR}/build/outputs/aar/android-release.aar"
if [ ! -f "$AAR_PATH" ]; then
    echo -e "${YELLOW}⚠️ 搜索所有 release 版本 AAR...${NC}"
    AAR_FILE=$(find "$ANDROID_PROJECT_DIR" -name "*.aar" | grep -E "release" | head -n 1)
    if [ -z "$AAR_FILE" ]; then
        echo -e "${RED}Error: AAR 打包失败${NC}"
        # 打印gradle构建日志（如果有）
        if [ -f "${ANDROID_PROJECT_DIR}/build/reports/build/execution/execution.log" ]; then
            cat "${ANDROID_PROJECT_DIR}/build/reports/build/execution/execution.log"
        fi
        exit 1
    fi
    AAR_PATH="$AAR_FILE"
fi
echo -e "${GREEN}✅ AAR 打包成功：$AAR_PATH${NC}"

# 收集产物（参考原作者输出格式）
mkdir -p "${PWD}/release"
cp "$CORE_SO" "${PWD}/release/"
cp "${JNI_DIR}/libletta_jni.so" "${PWD}/release/"
cp "$AAR_PATH" "${PWD}/release/letta-lite-android.aar"
cp "$HEADER_FILE" "${PWD}/release/"

echo -e "\n${GREEN}🎉 所有产物生成成功！适配天玑1200+NDK 27${NC}"
echo -e "${GREEN}📦 release 目录产物：${NC}"
ls -l "${PWD}/release/"
echo -e "\n${YELLOW}使用说明（参考原作者）：${NC}"
echo "1. 将 letta-lite-android.aar 复制到 Android 项目的 libs 目录"
echo "2. 在 app/build.gradle 中添加：implementation files('libs/letta-lite-android.aar')"
echo "3. 导入使用：import ai.letta.lite.LettaLite"
