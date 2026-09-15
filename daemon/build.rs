fn main() {
    println!("cargo:rerun-if-env-changed=DIFFREEL_BUILD_ID");
    let id = std::env::var("DIFFREEL_BUILD_ID").unwrap_or_else(|_| "local".into());
    assert!(
        id == "local"
            || (id.len() == 64
                && id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))),
        "DIFFREEL_BUILD_ID must be local or a lowercase SHA256"
    );
    println!("cargo:rustc-env=DIFFREEL_BUILD_ID={id}");
    println!(
        "cargo:rustc-env=DIFFREEL_TARGET={}",
        std::env::var("TARGET").unwrap()
    );
}
