//! xe-m2v-probe: runs AdrenoMetal's bridge self-test (compute kernel, render pass, zero-copy host import, and the
//! translation of QuartzCore's own Metal library) on the Vulkan driver behind the given loader. On the E16 that is our
//! ANV through /Library/GPUBundles/nvmtl/libvulkan.dylib (VK_ICD_FILENAMES picks intel_icd.json).
use nmb as bridge;

use std::ffi::CString;
use std::time::Instant;

unsafe extern "C" fn mark(m: u32) {
    eprintln!("  step 0x{m:04x}");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let loader = args.get(1).cloned().unwrap_or_else(|| "/Library/GPUBundles/nvmtl/libvulkan.dylib".into());
    let qc_path = args.get(2).cloned().unwrap_or_default();
    let cache = std::env::temp_dir().join("xe-m2v-cache");
    let _ = std::fs::create_dir_all(&cache);
    let qc = if qc_path.is_empty() { Vec::new() } else { std::fs::read(&qc_path).unwrap_or_default() };
    println!("loader {loader}\nquartzcore library: {} ({} bytes)", if qc_path.is_empty() { "-" } else { &qc_path }, qc.len());
    let l = CString::new(loader).unwrap();
    let c = CString::new(cache.to_string_lossy().into_owned()).unwrap();
    let mut out: bridge::NmbSelftest = unsafe { std::mem::zeroed() };
    let t0 = Instant::now();
    let r = unsafe { bridge::nmb_selftest(l.as_ptr(), c.as_ptr(), if qc.is_empty() { std::ptr::null() } else { qc.as_ptr() }, qc.len(), Some(mark), &mut out) };
    let msg_end = out.message.iter().position(|&b| b == 0).unwrap_or(out.message.len());
    println!("result 0x{r:04x} in {:.1} s", t0.elapsed().as_secs_f64());
    println!("compute_bad {}  render_bad {}  import_bad {}", out.compute_bad, out.render_bad, out.import_bad);
    println!("quartzcore: functions {}  kernels ok/failed {}/{}  vertex+fragment pairs ok/failed {}/{}",
             out.qc_functions, out.qc_kernels_ok, out.qc_kernels_failed, out.qc_pairs_ok, out.qc_pairs_failed);
    if r != 0 { println!("failed at 0x{:04x}: {}", out.stage, String::from_utf8_lossy(&out.message[..msg_end])); }
    println!("{}", if r == 0 && out.compute_bad == 0 && out.render_bad == 0 && out.import_bad == 0 { "PASS" } else { "FAIL" });
    std::process::exit(if r == 0 { 0 } else { 1 });
}
