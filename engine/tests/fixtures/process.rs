use std::{io::{self, Write}, process::Command, thread, time::Duration};
use std::sync::atomic::{AtomicBool, Ordering};
unsafe extern "C" { fn signal(signal: i32, handler: usize) -> usize; }

static TERMINATING: AtomicBool = AtomicBool::new(false);

extern "C" fn begin_shutdown(_: i32) {
    TERMINATING.store(true, Ordering::Relaxed);
}
fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("fail") => { println!("failure fixture"); std::process::exit(1); }
        Some("flood") => {
            println!("API_KEY=synthetic-test-value");
            for _ in 0..3000 { println!("{}", "x".repeat(8192)); }
            io::stdout().flush().unwrap();
        }
        Some("tree") => {
            let child = Command::new(std::env::current_exe().unwrap()).arg("descendant").spawn().unwrap();
            println!("child:{}", child.id()); io::stdout().flush().unwrap();
        }
        Some("slow-stop") => {
            unsafe { signal(15, begin_shutdown as *const () as usize); }
            println!("ready for slow shutdown");
            io::stdout().flush().unwrap();
            while !TERMINATING.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_millis(10));
            }
            println!("shutdown in progress");
            io::stdout().flush().unwrap();
            thread::sleep(Duration::from_secs(3));
            return;
        }
        Some("descendant") => { unsafe { signal(15, 1); } }
        _ => { println!("sleep fixture"); io::stdout().flush().unwrap(); }
    }
    loop { thread::sleep(Duration::from_secs(1)); }
}
