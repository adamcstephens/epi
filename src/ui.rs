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

pub struct Group {
    mp: indicatif::MultiProgress,
    header: ProgressBar,
    is_tty: bool,
}

impl Group {
    pub fn start(msg: &str) -> Self {
        let is_tty = Term::stderr().is_term();
        let mp = indicatif::MultiProgress::new();

        if is_tty {
            let header = mp.add(ProgressBar::new(0));
            header.set_style(ProgressStyle::with_template("{msg}").expect("invalid template"));
            let style = Style::new().for_stderr();
            header.set_message(format!("{} {msg}", style.apply_to("◇")));
            Self { mp, header, is_tty }
        } else {
            eprintln!("{msg}...");
            Self {
                mp,
                header: ProgressBar::hidden(),
                is_tty,
            }
        }
    }

    pub fn step(&self, msg: &str) -> GroupStep {
        if self.is_tty {
            let bar = self.mp.add(ProgressBar::new_spinner());
            bar.set_style(
                ProgressStyle::default_spinner()
                    .template("  {spinner:.yellow} {msg} {elapsed:.dim}")
                    .expect("invalid template")
                    .tick_strings(&["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏", " "]),
            );
            bar.set_message(msg.to_string());
            bar.enable_steady_tick(Duration::from_millis(80));
            GroupStep { bar, is_tty: true }
        } else {
            eprintln!("  {msg}...");
            GroupStep {
                bar: ProgressBar::hidden(),
                is_tty: false,
            }
        }
    }

    pub fn cached(&self, msg: &str) {
        if self.is_tty {
            let bar = self.mp.add(ProgressBar::new(0));
            bar.set_style(ProgressStyle::with_template("{msg}").expect("invalid template"));
            let style = Style::new().for_stderr().cyan();
            bar.finish_with_message(format!("  {} {msg}", style.apply_to("◆")));
        } else {
            eprintln!("  {msg}");
        }
    }

    pub fn finish(&self, msg: &str) {
        let style = Style::new().for_stderr().green();
        if self.is_tty {
            self.header
                .set_message(format!("{} {msg}", style.apply_to("✓")));
            self.header.finish();
        } else {
            eprintln!("{msg}");
        }
    }

    pub fn fail(&self, msg: &str) {
        let style = Style::new().for_stderr().red();
        if self.is_tty {
            self.header
                .set_message(format!("{} {msg}", style.apply_to("✗")));
            self.header.finish();
        } else {
            eprintln!("{msg}");
        }
    }
}

pub struct GroupStep {
    bar: ProgressBar,
    is_tty: bool,
}

impl GroupStep {
    pub fn finish(&self, msg: &str) {
        let style = Style::new().for_stderr().green();
        self.finish_with_icon(&format!("{}", style.apply_to("✓")), msg);
    }

    pub fn finish_cached(&self, msg: &str) {
        let style = Style::new().for_stderr().cyan();
        self.finish_with_icon(&format!("{}", style.apply_to("◆")), msg);
    }

    pub fn fail(&self, msg: &str) {
        let style = Style::new().for_stderr().red();
        self.finish_with_icon(&format!("{}", style.apply_to("✗")), msg);
    }

    fn finish_with_icon(&self, icon: &str, msg: &str) {
        if self.is_tty {
            self.bar
                .set_style(ProgressStyle::with_template("{msg}").expect("invalid template"));
            self.bar.finish_with_message(format!("  {icon} {msg}"));
        } else {
            eprintln!("  {msg}");
        }
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

    #[test]
    fn group_finish() {
        console::set_colors_enabled_stderr(false);
        let group = Group::start("Preparing");
        group.finish("Prepared");
    }

    #[test]
    fn group_fail() {
        console::set_colors_enabled_stderr(false);
        let group = Group::start("Preparing");
        group.fail("Preparation failed");
    }

    #[test]
    fn group_step_finish() {
        console::set_colors_enabled_stderr(false);
        let group = Group::start("Preparing");
        let step = group.step("Evaluating .#config");
        step.finish("Evaluated .#config");
        group.finish("Prepared");
    }

    #[test]
    fn group_step_fail() {
        console::set_colors_enabled_stderr(false);
        let group = Group::start("Preparing");
        let step = group.step("Evaluating .#config");
        step.fail("Evaluation failed");
        group.fail("Preparation failed");
    }

    #[test]
    fn group_step_finish_cached() {
        console::set_colors_enabled_stderr(false);
        let group = Group::start("Preparing");
        let step = group.step("Resolving .#config");
        step.finish_cached("Cached .#config");
        group.finish("Prepared");
    }

    #[test]
    fn group_cached() {
        console::set_colors_enabled_stderr(false);
        let group = Group::start("Preparing");
        group.cached("Cached .#config");
        group.finish("Prepared");
    }
}
