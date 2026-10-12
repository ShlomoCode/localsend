use anyhow::Context;
use crossterm::terminal::{Clear, ClearType};
use crossterm::{cursor, execute};
use localsend::util::filename;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Enters the alternate screen for a modal widget (the file picker or the
/// device list). The caller must suspend the log UI first and resume it
/// after [leave_alternate_screen].
pub fn enter_alternate_screen() -> anyhow::Result<()> {
    execute!(
        std::io::stdout(),
        crossterm::terminal::EnterAlternateScreen,
        cursor::Hide
    )?;
    Ok(())
}

/// Leaves the alternate screen. Must be called exactly once per enter.
///
/// Clears via crossterm, not `Terminal::clear`: the latter queries the
/// cursor position, whose response is read from the event stream but
/// the keyboard reader thread is parked in `crossterm::event::read()`,
/// so the query only ever returns after crossterm's 2s timeout.
pub fn leave_alternate_screen() {
    let _ = execute!(
        std::io::stdout(),
        Clear(ClearType::All),
        cursor::MoveTo(0, 0),
        crossterm::terminal::LeaveAlternateScreen,
        cursor::Show
    );
}

/// Clears the alternate screen without leaving it, for handing it over from
/// one modal to the next — leaving and re-entering would flash the main
/// screen in between.
pub fn clear_alternate_screen() {
    let _ = execute!(
        std::io::stdout(),
        Clear(ClearType::All),
        cursor::MoveTo(0, 0)
    );
}

pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    match unit {
        0 => format!("{bytes} B"),
        _ => format!("{value:.1} {}", UNITS[unit]),
    }
}

pub fn format_speed(bytes_per_sec: f64) -> String {
    format!("{}/s", format_bytes(bytes_per_sec.max(0.0) as u64))
}

pub fn format_duration(duration: Duration) -> String {
    let secs = duration.as_secs();
    let (h, m, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
    if h > 0 {
        format!("{h}h {m}m")
    } else if m > 0 {
        format!("{m}m {s}s")
    } else {
        format!("{s}s")
    }
}

/// The width of the terminal in columns, falling back to 120 when it cannot be
/// determined (e.g. when the output is not a terminal).
pub fn terminal_width() -> usize {
    crossterm::terminal::size()
        .map(|(w, _)| w as usize)
        .unwrap_or(120)
}

pub fn progress_bar(fraction: f64, width: usize) -> String {
    let filled = (fraction.clamp(0.0, 1.0) * width as f64).round() as usize;
    format!("{}{}", "#".repeat(filled), "-".repeat(width - filled))
}

/// A path in `dir` for `file_name` that does not exist yet, appending
/// ` (1)`, ` (2)`, … before the extension on collisions.
///
/// `file_name` comes from the sender and is untrusted: it is collapsed to its
/// final path component and sanitized for the local filesystem, so it can
/// neither escape the target directory nor carry illegal characters.
pub fn unique_path(dir: &Path, file_name: &str) -> anyhow::Result<PathBuf> {
    let original_name = filename::final_component(file_name);
    let mut counter = None;
    loop {
        let name = filename::sanitize_for_directory(original_name, dir, counter, false)?;
        let candidate = dir.join(name);
        match std::fs::symlink_metadata(&candidate) {
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(candidate),
            Ok(_) => {}
            Err(err) => {
                return Err(err)
                    .with_context(|| format!("Could not inspect {}", candidate.display()));
            }
        }
        counter = Some(match counter {
            None => 1,
            Some(value) => value
                .checked_add(1)
                .context("Filename collision counter exhausted")?,
        });
    }
}

/// Estimates the transfer speed from cumulative byte counts, smoothed with an
/// exponential moving average.
pub struct SpeedMeter {
    last_bytes: u64,
    last_time: Instant,
    ema: f64,
}

impl SpeedMeter {
    pub fn new() -> Self {
        Self {
            last_bytes: 0,
            last_time: Instant::now(),
            ema: 0.0,
        }
    }

    pub fn update(&mut self, bytes_now: u64) -> f64 {
        let now = Instant::now();
        let dt = now.duration_since(self.last_time).as_secs_f64();
        if dt < 0.1 {
            return self.ema;
        }
        let instantaneous = bytes_now.saturating_sub(self.last_bytes) as f64 / dt;
        self.ema = match self.ema {
            0.0 => instantaneous,
            ema => ema * 0.7 + instantaneous * 0.3,
        };
        self.last_bytes = bytes_now;
        self.last_time = now;
        self.ema
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collision_at_filename_limit_remains_writable_and_keeps_extension() {
        let dir = std::env::temp_dir().join(format!("localsend-cli-name-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let name = format!("{}.mp4", "a".repeat(251));
        let first = unique_path(&dir, &name).unwrap();
        std::fs::write(&first, b"first").unwrap();
        let second = unique_path(&dir, &name).unwrap();
        assert_ne!(first, second);
        assert!(
            second
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .ends_with(" (1).mp4")
        );
        std::fs::write(&second, b"second").unwrap();
        assert_eq!(std::fs::read(&first).unwrap(), b"first");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn compound_extension_collision_uses_original_final_component() {
        let dir =
            std::env::temp_dir().join(format!("localsend-cli-compound-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let name = format!("{}.tar.gz", "a".repeat(248));
        let first = unique_path(&dir, &format!("../../folder/{name}")).unwrap();
        std::fs::write(&first, b"first").unwrap();
        let second = unique_path(&dir, &format!("..\\folder\\{name}")).unwrap();
        assert!(second.starts_with(&dir));
        assert!(
            second
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .ends_with(" (1).tar.gz")
        );
        std::fs::write(&second, b"second").unwrap();
        assert_eq!(std::fs::read(&first).unwrap(), b"first");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn dangling_symlink_is_a_collision() {
        let dir =
            std::env::temp_dir().join(format!("localsend-cli-symlink-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let link = dir.join("archive.tar.gz");
        std::os::unix::fs::symlink("missing-target", &link).unwrap();
        let second = unique_path(&dir, "archive.tar.gz").unwrap();
        assert_eq!(second.file_name().unwrap(), "archive (1).tar.gz");
        assert_eq!(
            std::fs::read_link(&link).unwrap(),
            std::path::Path::new("missing-target")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
