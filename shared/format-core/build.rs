fn main() {
    println!("cargo:rerun-if-changed=src/papria_format_core.udl");
    println!("cargo:rerun-if-changed=native/libmobi_shim.c");
    println!("cargo:rerun-if-changed=native/libmobi_shim.h");
    println!("cargo:rerun-if-changed=vendor/libmobi/src");

    let sources = [
        "native/libmobi_shim.c",
        "vendor/libmobi/src/buffer.c",
        "vendor/libmobi/src/compression.c",
        "vendor/libmobi/src/debug.c",
        "vendor/libmobi/src/index.c",
        "vendor/libmobi/src/memory.c",
        "vendor/libmobi/src/meta.c",
        "vendor/libmobi/src/miniz.c",
        "vendor/libmobi/src/parse_rawml.c",
        "vendor/libmobi/src/read.c",
        "vendor/libmobi/src/structure.c",
        "vendor/libmobi/src/util.c",
    ];
    let target = std::env::var("TARGET").expect("Cargo must set TARGET for the C compiler");
    let mut build = cc::Build::new();
    build
        .files(sources)
        .include("native")
        .include("vendor/libmobi/src")
        .define("USE_MINIZ", None)
        .define("MOBI_INLINE", Some("inline"))
        .define("PACKAGE_VERSION", Some("\"0.12\""))
        .flag_if_supported("-std=c99")
        .warnings(false);

    // Rust's Apple targets default to iOS 10. Papria supports iOS 15, so the
    // vendored C objects must use the same minimum deployment version. A
    // current SDK otherwise emits helpers unavailable to the Rust link target.
    match target.as_str() {
        "aarch64-apple-ios" => build.flag("-miphoneos-version-min=15.0"),
        "aarch64-apple-ios-sim" | "x86_64-apple-ios" => {
            build.flag("-mios-simulator-version-min=15.0")
        }
        _ => &mut build,
    };
    build.compile("papria_libmobi");

    uniffi::generate_scaffolding("src/papria_format_core.udl")
        .expect("generate UniFFI scaffolding");
}
