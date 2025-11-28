use std::env;
use std::path::PathBuf;

fn main() {
    // 🔧 新增：千问建议的 libunwind.a 静态链接逻辑（不影响原有功能）
    if let Ok(unwind_lib_path) = env::var("UNWIND_LIB_PATH") {
        // 告诉 Cargo 链接静态库 unwind（对应 libunwind.a）
        println!("cargo:rustc-link-lib=static=unwind");
        // 告诉 Cargo 静态库的搜索路径
        println!("cargo:rustc-link-search=native={}", unwind_lib_path);
        // 可选调试日志（编译时会显示，方便确认是否生效）
        println!("cargo:warning=Linked libunwind.a from: {}", unwind_lib_path);
    } else {
        // 若未传递路径，编译报错（避免静默失败）
        panic!("环境变量 UNWIND_LIB_PATH 未设置，请在构建脚本中传递 libunwind.a 所在目录");
    }

    // 🔧 原有：生成 C 头文件的逻辑（完全保留，不做任何修改）
    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let output_dir = PathBuf::from(&crate_dir).join("include");
    
    std::fs::create_dir_all(&output_dir).unwrap();
    
    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_language(cbindgen::Language::C)
        .with_include_guard("LETTA_LITE_H")
        .with_autogen_warning("/* This file is auto-generated. Do not modify manually. */")
        .generate()
        .expect("Unable to generate bindings")
        .write_to_file(output_dir.join("letta_lite.h"));
}
