use std::env;
use std::path::PathBuf;

fn main() {
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