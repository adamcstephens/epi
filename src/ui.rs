use console::{Style, Term};
use indicatif::{ProgressBar, ProgressStyle};
use std::time::Duration;

pub struct Step {
    bar: ProgressBar,
    is_tty: bool,
}

impl Step {
    pub fn start(msg: &str) -> Self {
        let is_tty = Term::stderr().is_term();
        if is_tty {
            let bar = ProgressBar::new_spinner();
            bar.set_style(
                ProgressStyle::default_spinner()
                    .template("{spinner:.yellow} {msg} {elapsed:.dim}")
                    .expect("invalid template")
                    .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", " "]),
            );
            bar.set_message(msg.to_string());
            bar.enable_steady_tick(Duration::from_millis(80));
            Self { bar, is_tty }
        } else {
            eprintln!("{msg}...");
            Self {
                bar: ProgressBar::hidden(),
                is_tty,
            }
        }
    }

    pub fn finish(&self, msg: &str) {
        let style = Style::new().for_stderr().green();
        if self.is_tty {
            self.bar.finish_and_clear();
        }
        eprintln!("{} {msg}", style.apply_to("✓"));
    }

    pub fn fail(&self, msg: &str) {
        let style = Style::new().for_stderr().red();
        if self.is_tty {
            self.bar.finish_and_clear();
        }
        eprintln!("{} {msg}", style.apply_to("✗"));
    }
}

pub fn info(msg: &str) {
    eprintln!("{msg}");
}

pub fn warn(msg: &str) {
    let style = Style::new().for_stderr().yellow();
    eprintln!("{} {msg}", style.apply_to("warning:"));
}

pub fn error(err: &anyhow::Error) {
    let style = Style::new().for_stderr().red().bold();
    let dim = Style::new().for_stderr().dim();
    eprintln!("{} {}", style.apply_to("✗ error:"), err);
    for cause in err.chain().skip(1) {
        eprintln!("  {}", dim.apply_to(cause));
    }
}

pub fn status_dot(running: bool) -> String {
    if running {
        let style = Style::new().for_stdout().green();
        format!("{} running", style.apply_to("●"))
    } else {
        let style = Style::new().for_stdout().dim();
        format!("{} stopped", style.apply_to("○"))
    }
}

pub fn bold(text: &str) -> String {
    let style = Style::new().for_stdout().bold();
    format!("{}", style.apply_to(text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_dot_running() {
        console::set_colors_enabled(false);
        console::set_colors_enabled_stderr(false);
        let dot = status_dot(true);
        assert!(dot.contains("●"));
        assert!(dot.contains("running"));
    }

    #[test]
    fn status_dot_stopped() {
        console::set_colors_enabled(false);
        console::set_colors_enabled_stderr(false);
        let dot = status_dot(false);
        assert!(dot.contains("○"));
        assert!(dot.contains("stopped"));
    }

    #[test]
    fn error_formats_chain() {
        console::set_colors_enabled_stderr(false);
        let err = anyhow::anyhow!("outer").context("inner");
        error(&err);
    }

    #[test]
    fn step_non_tty_finish() {
        // In test, stderr is not a TTY — verifies non-TTY path doesn't panic
        let step = Step::start("test operation");
        step.finish("test done");
    }

    #[test]
    fn step_non_tty_fail() {
        let step = Step::start("test operation");
        step.fail("test failed");
    }
}
