fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    for (var, file) in [("NMB_FIXTURE_AIR", "runtime_examples.air"), ("NMB_SCANOUT_AIR", "scanout_convert.air"), ("NMB_FC_AIR", "fc.air")] {
        let path = std::env::var(var).unwrap_or_else(|_| format!("{dir}/air/{file}"));
        println!("cargo:rustc-env={var}={path}");
        println!("cargo:rerun-if-changed={path}");
    }
    println!("cargo:rustc-env=NMB_RUNTIME_ID=xe-m2v-probe");
}
