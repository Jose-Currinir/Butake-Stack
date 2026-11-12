use std::{io::{self, Write}, process::Command, thread, time::Duration};
unsafe extern "C" { fn signal(signal: i32, handler: usize) -> usize; }
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
        Some("descendant") => { unsafe { signal(15, 1); } }
        _ => { println!("sleep fixture"); io::stdout().flush().unwrap(); }
    }
    loop { thread::sleep(Duration::from_secs(1)); }
}
