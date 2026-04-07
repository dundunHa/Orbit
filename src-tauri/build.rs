use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

fn main() {
    stage_dev_helper();
    tauri_build::build()
}

fn stage_dev_helper() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let target = std::env::var("TARGET").unwrap();
    let profile = std::env::var("PROFILE").unwrap_or_else(|_| "debug".to_string());
    if profile != "debug" {
        return;
    }

    let helper_dir = manifest_dir.join("binaries");
    let helper_path = helper_dir.join(format!("orbit-helper-{target}"));
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let cli_dir = out_dir
        .ancestors()
        .nth(3)
        .expect("OUT_DIR missing expected target profile layout");
    let cli_path = cli_dir.join("orbit-cli");

    fs::create_dir_all(&helper_dir).expect("failed to create src-tauri/binaries");
    fs::write(
        &helper_path,
        format!(
            "#!/bin/sh\nexec '{}' \"$@\"\n",
            cli_path.to_string_lossy().replace('\'', "'\"'\"'")
        ),
    )
    .expect("failed to write dev helper shim");

    let mut perms = fs::metadata(&helper_path)
        .expect("failed to read helper shim metadata")
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&helper_path, perms).expect("failed to mark helper shim executable");
}
