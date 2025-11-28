use std::env;
use std::path::PathBuf;

fn main() {
    // 自动找 libunwind.a（简化配置，不用手动传路径）
    if let Ok(ndk_home) = env::var("ANDROID_NDK_HOME") {
        let unwind_path = format!(
            "{}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux/aarch64",
            ndk_home
        );
        println!("cargo:rustc-link-lib=static=unwind");
        println!("cargo:rustc-link-search=native={}", unwind_path);
    }

    // 原有头文件生成逻辑（不变）
    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let output_dir = PathBuf::from(&crate_dir).join("include");
    std::fs::create_dir_all(&output_dir).unwrap();
    
    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_language(cbindgen::Language::C)
        .with_include_guard("LETTA_LITE_H")
        .with_autogen_warning("/* Auto-generated, do not modify */")
        .generate()
        .expect("Failed to generate bindings")
        .write_to_file(output_dir.join("letta_lite.h"));
}
