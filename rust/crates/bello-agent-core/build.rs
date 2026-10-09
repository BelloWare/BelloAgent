//! Compile only the source decoder, never the Swift host or native authority.
use serde_json::{Value, json};
use std::{env, fs, path::PathBuf, process::Command};

fn run(program: &str, arguments: &[&str]) -> String {
    let result = Command::new(program)
        .args(arguments)
        .output()
        .unwrap_or_else(|error| panic!("source UTF-8 bridge: cannot run {program}: {error}"));
    assert!(
        result.status.success(),
        "source UTF-8 bridge: {program} {arguments:?} failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    String::from_utf8(result.stdout)
        .expect("source UTF-8 bridge: non-UTF-8 toolchain response")
        .trim()
        .to_owned()
}

fn main() {
    private_sqlite_build_gate();
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=native/source_utf8.swift");
    // This precedes all Apple environment/path discovery, including OUT_DIR.
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    for name in ["MACOSX_DEPLOYMENT_TARGET", "DEVELOPER_DIR", "SDKROOT"] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    assert_eq!(
        env::var("TARGET").as_deref(),
        Ok("aarch64-apple-darwin"),
        "source UTF-8 bridge supports the Apple Silicon macOS target"
    );
    assert!(
        env::var("HOST").is_ok_and(|host| host.ends_with("-apple-darwin")),
        "source UTF-8 bridge requires a macOS build host with Xcode; no cross-host stub exists"
    );
    assert_eq!(
        env::var("MACOSX_DEPLOYMENT_TARGET").as_deref(),
        Ok("14.0"),
        "build Rust and Swift together with MACOSX_DEPLOYMENT_TARGET=14.0"
    );
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo OUT_DIR"));
    let source =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("native/source_utf8.swift");
    let sdk = run("/usr/bin/xcrun", &["--sdk", "macosx", "--show-sdk-path"]);
    if let Some(configured) = env::var_os("SDKROOT") {
        let configured = PathBuf::from(configured);
        assert!(
            configured == std::path::Path::new("macosx")
                || configured.canonicalize().ok() == PathBuf::from(&sdk).canonicalize().ok(),
            "SDKROOT must select the same macOS SDK as xcrun"
        );
    }
    let compiler = run("/usr/bin/xcrun", &["--find", "swiftc"]);
    println!("cargo:rerun-if-changed={compiler}");
    let target = "arm64-apple-macosx14.0";
    let info: Value = serde_json::from_str(&run(
        &compiler,
        &["-print-target-info", "-target", target, "-sdk", &sdk],
    ))
    .expect("Swift target-info JSON");
    assert_eq!(info["target"]["triple"], target);
    let paths = info["paths"]["runtimeLibraryPaths"]
        .as_array()
        .expect("Swift runtimeLibraryPaths");
    assert!(
        !paths.is_empty(),
        "Swift runtime library paths are required"
    );
    for path in paths {
        let path = path.as_str().expect("Swift runtime library path");
        assert!(
            PathBuf::from(path).is_absolute(),
            "absolute Swift search path"
        );
        println!("cargo:rustc-link-search=native={path}");
    }
    for library in info["target"]["compatibilityLibraries"]
        .as_array()
        .expect("Swift compatibilityLibraries")
    {
        let name = library["libraryName"]
            .as_str()
            .expect("Swift compatibility name");
        assert!(name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'));
        let filter = library["filter"]
            .as_str()
            .expect("Swift compatibility filter");
        assert!(matches!(filter, "all" | "static" | "dynamic"));
        if filter == "dynamic" {
            continue;
        }
        let force = library["forceLoad"].as_bool().unwrap_or(true);
        let modifier = if force { ":+whole-archive" } else { "" };
        println!("cargo:rustc-link-lib=static{modifier}={name}");
    }
    let archive = output.join("libbello_source_utf8.a");
    let header = output.join("source_utf8-Swift.h");
    let cache = output.join("swift-module-cache");
    let optimization = if env::var("PROFILE").as_deref() == Ok("release") {
        "-O"
    } else {
        "-Onone"
    };
    let args = vec![
        "-swift-version",
        "5",
        "-target",
        target,
        "-sdk",
        &sdk,
        "-parse-as-library",
        "-emit-library",
        "-static",
        optimization,
        "-module-name",
        "BelloSourceUTF8",
        "-module-cache-path",
        cache.to_str().unwrap(),
        "-emit-objc-header",
        "-emit-objc-header-path",
        header.to_str().unwrap(),
        source.to_str().unwrap(),
        "-o",
        archive.to_str().unwrap(),
    ];
    run(&compiler, &args);
    println!("cargo:rustc-link-search=native={}", output.display());
    // ObjC lookup does not create a normal undefined symbol reference to the
    // Swift class. Retain this small archive through rlib/downstream App links.
    println!("cargo:rustc-link-lib=static:+whole-archive=bello_source_utf8");
    let record = json!({
        "schema": 1, "target": target, "deployment_target": "14.0",
        "compiler": compiler, "compiler_version": run(&compiler, &["--version"]),
        "sdk": sdk, "sdk_version": run("/usr/bin/xcrun", &["--sdk", "macosx", "--show-sdk-version"]),
        "target_info": info, "arguments": args, "source": source,
        "archive": archive, "header": header,
    });
    fs::write(
        output.join("source-utf8-build.json"),
        serde_json::to_vec_pretty(&record).unwrap(),
    )
    .expect("write source UTF-8 build identity");
}

/// Cargo does not discover a manifest's configuration when invoked from an
/// unrelated working directory. Refuse that unsupported build instead of silently
/// compiling a spill-capable library. Use --config <repo>/.cargo/config.toml there.
fn private_sqlite_build_gate() {
    const FLAGS: &str = "-DSQLITE_STMTJRNL_SPILL=-1 -DSQLITE_TEMP_STORE=3";
    println!("cargo:rerun-if-env-changed=LIBSQLITE3_FLAGS");
    assert_eq!(
        env::var("LIBSQLITE3_FLAGS").as_deref(),
        Ok(FLAGS),
        "private search requires the checked-in Cargo no-spill configuration"
    );
    for name in [
        "LIBSQLITE3_SYS_USE_PKG_CONFIG",
        "LIBSQLITE3_SYS_BUNDLING",
        "SQLITE_MAX_VARIABLE_NUMBER",
        "SQLITE_MAX_EXPR_DEPTH",
        "SQLITE_MAX_COLUMN",
        "SQLITE3_LIB_DIR",
        "SQLITE3_INCLUDE_DIR",
        "SQLITE3_STATIC",
        "SQLCIPHER_LIB_DIR",
        "SQLCIPHER_INCLUDE_DIR",
        "SQLCIPHER_STATIC",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
        assert!(
            env::var_os(name).is_none(),
            "private search rejects SQLite linkage overrides"
        );
    }
    // cc accepts target-specific CFLAGS as well as the generic spellings. Reject
    // external C preprocessor overrides (including an unreported SHM directory).
    // Compiler/sysroot selection remains supported through CC, SDKROOT and the
    // documented build environment; flags inside reviewed build.rs are unchanged.
    let mut names = vec![
        "CFLAGS".to_owned(),
        "CPPFLAGS".to_owned(),
        "HOST_CFLAGS".to_owned(),
        "TARGET_CFLAGS".to_owned(),
    ];
    for key in ["HOST", "TARGET"] {
        if let Ok(target) = env::var(key) {
            names.push(format!("CFLAGS_{target}"));
            names.push(format!("CFLAGS_{}", target.replace('-', "_")));
        }
    }
    for name in names {
        println!("cargo:rerun-if-env-changed={name}");
        assert!(
            env::var_os(&name).is_none_or(|value| value.is_empty()),
            "private search rejects external CFLAGS/CPPFLAGS overrides"
        );
    }
    let mut compilers = vec![
        "CC".to_owned(),
        "HOST_CC".to_owned(),
        "TARGET_CC".to_owned(),
    ];
    for key in ["HOST", "TARGET"] {
        if let Ok(target) = env::var(key) {
            compilers.push(format!("CC_{target}"));
            compilers.push(format!("CC_{}", target.replace('-', "_")));
        }
    }
    for name in compilers {
        println!("cargo:rerun-if-env-changed={name}");
        if let Some(value) = env::var_os(&name) {
            let plain = value.to_str().is_some_and(|value| {
                !value.is_empty()
                    && !value.chars().any(char::is_whitespace)
                    && !value.starts_with('-')
            });
            assert!(
                plain || std::path::Path::new(&value).is_file(),
                "private search requires a plain compiler name/path without embedded flags"
            );
        }
    }
    println!("cargo:rerun-if-env-changed=CC_KNOWN_WRAPPER_CUSTOM");
    assert!(
        env::var_os("CC_KNOWN_WRAPPER_CUSTOM").is_none(),
        "private search rejects unreviewed custom C compiler wrappers"
    );
}
