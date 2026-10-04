//! Filename sanitization for untrusted, peer-supplied file names.

/// Characters that are illegal on Windows and FAT volumes.
const ILLEGAL_WINDOWS_CHARS: &[char] = &['<', '>', ':', '"', '/', '\\', '|', '?', '*'];

/// Characters that are illegal on HFS/APFS. `:` is the classic Mac path
/// separator and still shows up as `/` in Finder.
const ILLEGAL_HFS_CHARS: &[char] = &['/', ':'];

/// Characters that are illegal on POSIX filesystems.
const ILLEGAL_POSIX_CHARS: &[char] = &['/'];

/// Device names Windows reserves regardless of extension.
const RESERVED_WINDOWS_NAMES: &[&str] = &[
    "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
    "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
];

/// Maximum file name length: UTF-16 code units under Windows rules, bytes
/// under all other rules.
const MAX_LEN: usize = 255;

/// The naming rules to apply, selected by target filesystem rather than by OS
/// so that callers can sanitize for a destination that is not the local one
/// (a SAF tree on external FAT storage, for instance).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rules {
    /// NTFS: illegal characters, reserved device names, no trailing `.` or ` `.
    Windows,
    /// HFS+/APFS: `/` and `:`.
    Hfs,
    /// FAT/exFAT, the common case for Android external storage: the Windows
    /// character set without the reserved names.
    Fat,
    /// POSIX: `/` and NUL only.
    Posix,
    /// The intersection of all of the above. Use when the destination
    /// filesystem is unknown or the file may be copied between platforms.
    Universal,
}

impl Rules {
    /// The rules for the platform this binary was compiled for.
    pub const fn current() -> Self {
        if cfg!(target_os = "windows") {
            Self::Windows
        } else if cfg!(any(target_os = "macos", target_os = "ios")) {
            Self::Hfs
        } else if cfg!(target_os = "android") {
            Self::Fat
        } else if cfg!(unix) {
            Self::Posix
        } else {
            Self::Universal
        }
    }

    fn illegal_chars(self) -> &'static [char] {
        match self {
            Self::Windows | Self::Fat => ILLEGAL_WINDOWS_CHARS,
            Self::Hfs => ILLEGAL_HFS_CHARS,
            Self::Posix => ILLEGAL_POSIX_CHARS,
            // `Universal` is handled by combining the sets, see `is_illegal_char`.
            Self::Universal => &[],
        }
    }

    fn is_illegal_char(self, c: char) -> bool {
        if c.is_control() {
            return true;
        }
        match self {
            Self::Universal => ILLEGAL_WINDOWS_CHARS.contains(&c) || ILLEGAL_HFS_CHARS.contains(&c),
            _ => self.illegal_chars().contains(&c),
        }
    }

    /// Whether reserved device names and trailing `.`/` ` matter.
    fn is_windows_like(self) -> bool {
        matches!(self, Self::Windows | Self::Universal)
    }

    fn name_len(self, name: &str) -> usize {
        match self {
            Self::Windows => name.encode_utf16().count(),
            _ => name.len(),
        }
    }

    fn truncate(self, name: &mut String) {
        match self {
            Self::Windows => truncate_utf16(name, MAX_LEN),
            _ => truncate_bytes(name, MAX_LEN),
        }
    }
}

/// Options for [`sanitize_with`].
#[derive(Debug, Clone, Copy)]
pub struct Options<'a> {
    /// Substituted for each illegal character.
    pub replacement: &'a str,
    /// Used when sanitization leaves the name empty.
    pub placeholder: &'a str,
}

impl Default for Options<'_> {
    fn default() -> Self {
        Self {
            replacement: "_",
            placeholder: "untitled",
        }
    }
}

/// Rewrites `name` into a file name that is legal under `rules`, using the
/// default [`Options`].
///
/// `name` must already be a single path segment; this does not split paths and
/// will replace any separator it finds. Callers holding a peer-supplied path
/// should take the last segment first — see [`sanitize_path`].
pub fn sanitize(name: &str, rules: Rules) -> String {
    sanitize_with(name, rules, &Options::default())
}

/// [`sanitize`] with explicit replacement and placeholder strings.
pub fn sanitize_with(name: &str, rules: Rules, options: &Options) -> String {
    let mut result = String::with_capacity(name.len());
    for c in name.chars() {
        if rules.is_illegal_char(c) {
            result.push_str(options.replacement);
        } else {
            result.push(c);
        }
    }

    if rules.is_windows_like() {
        collapse_trailing_run(&mut result, options.replacement);

        if let Some(reserved) = reserved_prefix(&result) {
            result = format!("{}{}", options.replacement, &result[reserved.len()..]);
        }
    }

    rules.truncate(&mut result);

    if rules.is_windows_like() {
        // Truncation can cut right after a `.` or ` `, leaving a trailing run
        // that did not exist before the cut.
        collapse_trailing_run(&mut result, options.replacement);
        rules.truncate(&mut result);
    }

    if result.is_empty() || is_relative(&result) {
        result = options.placeholder.to_string();
        rules.truncate(&mut result);
    }

    result
}

/// Replaces a trailing run of `.`/` ` with a single `replacement`.
fn collapse_trailing_run(result: &mut String, replacement: &str) {
    let trimmed_len = result.trim_end_matches(['.', ' ']).len();
    if trimmed_len != result.len() {
        result.truncate(trimmed_len);
        result.push_str(replacement);
    }
}

/// Whether `name` is already legal under `rules`, i.e. whether [`sanitize`]
/// would leave it untouched. Suitable for validating user input before it is
/// written.
pub fn is_valid(name: &str, rules: Rules) -> bool {
    if name.is_empty() || rules.name_len(name) > MAX_LEN || is_relative(name) {
        return false;
    }

    if name.chars().any(|c| rules.is_illegal_char(c)) {
        return false;
    }

    if rules.is_windows_like()
        && (name.ends_with('.') || name.ends_with(' ') || reserved_prefix(name).is_some())
    {
        return false;
    }

    true
}

/// Sanitizes a peer-supplied *path* — a name that may carry directory
/// components, as protocol v2 allows for folder transfers — into a single
/// legal file name.
///
/// Only the last segment survives, so `../../etc/passwd` becomes `passwd`:
/// this collapses the path rather than preserving the directory structure.
pub fn sanitize_path(path: &str, rules: Rules) -> String {
    let last = path
        .rsplit(['/', '\\'])
        .find(|segment| !segment.is_empty() && !is_relative(segment))
        .unwrap_or("");

    sanitize(last, rules)
}

/// Returns the reserved device name `name` starts with, if its stem (the part
/// before the first `.`) is reserved.
fn reserved_prefix(name: &str) -> Option<&'static str> {
    let stem = name.split('.').next().unwrap_or(name);
    RESERVED_WINDOWS_NAMES
        .iter()
        .copied()
        .find(|reserved| stem.eq_ignore_ascii_case(reserved))
}

fn is_relative(name: &str) -> bool {
    name == "." || name == ".."
}

/// Truncates in place to at most `max` bytes, cutting on a character boundary.
fn truncate_bytes(value: &mut String, max: usize) {
    if value.len() <= max {
        return;
    }

    let mut end = max;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value.truncate(end);
}

/// Truncates in place to at most `max` UTF-16 code units, keeping whole chars.
fn truncate_utf16(value: &mut String, max: usize) {
    let mut units = 0;
    for (index, c) in value.char_indices() {
        units += c.len_utf16();
        if units > max {
            value.truncate(index);
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_replaces_illegal_characters() {
        assert_eq!(
            sanitize("a<b>c:d\"e/f\\g|h?i*j", Rules::Windows),
            "a_b_c_d_e_f_g_h_i_j"
        );
        assert_eq!(sanitize("a/b:c", Rules::Hfs), "a_b_c");
        assert_eq!(sanitize("a/b:c", Rules::Posix), "a_b:c");
        assert_eq!(sanitize("a\u{0}b\u{7f}c", Rules::Posix), "a_b_c");
    }

    #[test]
    fn test_keeps_legal_names() {
        for rules in [
            Rules::Windows,
            Rules::Hfs,
            Rules::Fat,
            Rules::Posix,
            Rules::Universal,
        ] {
            assert_eq!(
                sanitize("holiday photo (1).jpg", rules),
                "holiday photo (1).jpg"
            );
            assert_eq!(sanitize("Ünïcödé — 文件.txt", rules), "Ünïcödé — 文件.txt");
        }
    }

    #[test]
    fn test_windows_trailing_characters() {
        assert_eq!(sanitize("report.", Rules::Windows), "report_");
        assert_eq!(sanitize("report...  ", Rules::Windows), "report_");
        assert_eq!(sanitize("report.", Rules::Posix), "report.");
        assert_eq!(sanitize("report.", Rules::Fat), "report.");
    }

    #[test]
    fn test_reserved_windows_names() {
        assert_eq!(sanitize("con", Rules::Windows), "_");
        assert_eq!(sanitize("NUL.txt", Rules::Windows), "_.txt");
        assert_eq!(sanitize("com9.tar.gz", Rules::Windows), "_.tar.gz");
        // Only the exact stem is reserved.
        assert_eq!(sanitize("console.txt", Rules::Windows), "console.txt");
        assert_eq!(sanitize("com10.txt", Rules::Windows), "com10.txt");
        // FAT has no reserved names.
        assert_eq!(sanitize("con", Rules::Fat), "con");
    }

    #[test]
    fn test_placeholder() {
        assert_eq!(sanitize("", Rules::Posix), "untitled");
        assert_eq!(sanitize(".", Rules::Posix), "untitled");
        assert_eq!(sanitize("..", Rules::Posix), "untitled");
        assert_eq!(sanitize("///", Rules::Posix), "___");

        let options = Options {
            replacement: "",
            placeholder: "unnamed",
        };
        assert_eq!(sanitize_with("///", Rules::Posix, &options), "unnamed");
        assert_eq!(sanitize_with("a/b", Rules::Posix, &options), "ab");
    }

    #[test]
    fn test_truncates_on_char_boundary() {
        let long = "ä".repeat(200); // 400 bytes
        let sanitized = sanitize(&long, Rules::Posix);
        assert_eq!(sanitized.len(), MAX_LEN - 1); // 254: 127 × 2 bytes
        assert!(sanitized.chars().all(|c| c == 'ä'));
    }

    #[test]
    fn test_windows_keeps_reported_japanese_filename() {
        let name = "土曜のあさはほめるちゃん 20260926 ＃124「関西のいま気になるエリアのええところ“ほめるポイント＝ほめポ”を見つけながら、ぶらりするほっこりトークがたっぷりのほめぶら番組！今回は、“グラングリーン大阪”をぶらり！」.mp4";
        assert_eq!(name.encode_utf16().count(), 116);
        assert_eq!(name.len(), 314);
        assert!(is_valid(name, Rules::Windows));
        assert_eq!(sanitize(name, Rules::Windows), name);
        assert!(!is_valid(name, Rules::Posix));
    }

    #[test]
    fn test_windows_utf16_boundary_does_not_split_emoji() {
        let at_limit = format!("{}😀b", "a".repeat(252));
        assert_eq!(at_limit.encode_utf16().count(), MAX_LEN);
        assert!(is_valid(&at_limit, Rules::Windows));
        assert_eq!(sanitize(&at_limit, Rules::Windows), at_limit);

        let too_long = format!("{}😀b", "a".repeat(253));
        assert_eq!(too_long.encode_utf16().count(), MAX_LEN + 1);
        assert!(!is_valid(&too_long, Rules::Windows));
        let sanitized = sanitize(&too_long, Rules::Windows);
        assert_eq!(sanitized, format!("{}😀", "a".repeat(253)));
        assert_eq!(sanitized.encode_utf16().count(), MAX_LEN);
        assert!(is_valid(&sanitized, Rules::Windows));

        let emoji_over_boundary = format!("{}😀", "a".repeat(254));
        assert_eq!(
            sanitize(&emoji_over_boundary, Rules::Windows),
            "a".repeat(254)
        );
    }

    #[test]
    fn test_windows_custom_replacement_and_placeholder_use_utf16_limit() {
        let options = Options {
            replacement: "😀",
            placeholder: &"界".repeat(MAX_LEN),
        };
        let name = format!("{}/b", "a".repeat(252));
        assert_eq!(
            sanitize_with(&name, Rules::Windows, &options),
            format!("{}😀b", "a".repeat(252))
        );

        let empty_replacement = Options {
            replacement: "",
            ..options
        };
        let placeholder = sanitize_with("/", Rules::Windows, &empty_replacement);
        assert_eq!(placeholder.encode_utf16().count(), MAX_LEN);
        assert_eq!(placeholder, options.placeholder);
        assert!(is_valid(&placeholder, Rules::Windows));
    }

    /// Truncation must not leave a trailing `.` or ` ` behind on Windows-like
    /// rules — the cut can land right after one.
    #[test]
    fn test_truncation_does_not_expose_trailing_run() {
        let dot = format!("{}.{}", "a".repeat(254), "b".repeat(10));
        let sanitized = sanitize(&dot, Rules::Windows);
        assert_eq!(sanitized, format!("{}_", "a".repeat(254)));
        assert!(is_valid(&sanitized, Rules::Windows));

        let space = format!("{} {}", "a".repeat(254), "b".repeat(10));
        assert_eq!(
            sanitize(&space, Rules::Windows),
            format!("{}_", "a".repeat(254))
        );

        // POSIX allows trailing dots, so the cut stays as-is there.
        assert_eq!(
            sanitize(&dot, Rules::Posix),
            format!("{}.", "a".repeat(254))
        );
    }

    #[test]
    fn test_sanitize_path_collapses_directories() {
        assert_eq!(sanitize_path("../../etc/passwd", Rules::Posix), "passwd");
        assert_eq!(sanitize_path("a/b/c.txt", Rules::Posix), "c.txt");
        assert_eq!(
            sanitize_path("C:\\Windows\\evil.exe", Rules::Windows),
            "evil.exe"
        );
        assert_eq!(sanitize_path("dir/", Rules::Posix), "dir");
        assert_eq!(sanitize_path("..", Rules::Posix), "untitled");
        assert_eq!(sanitize_path("/", Rules::Posix), "untitled");
    }

    #[test]
    fn test_is_valid() {
        assert!(is_valid("photo.jpg", Rules::Windows));
        assert!(!is_valid("", Rules::Windows));
        assert!(!is_valid("a:b", Rules::Windows));
        assert!(!is_valid("a:b", Rules::Hfs));
        assert!(is_valid("a:b", Rules::Posix));
        assert!(!is_valid("con.txt", Rules::Windows));
        assert!(is_valid("con.txt", Rules::Posix));
        assert!(!is_valid("trailing.", Rules::Windows));
        assert!(!is_valid("..", Rules::Posix));
        assert!(!is_valid(&"a".repeat(256), Rules::Posix));
        assert!(is_valid(&"a".repeat(255), Rules::Posix));
    }

    /// `is_valid` must agree with `sanitize` — otherwise a name the UI accepts
    /// still gets rewritten on save, or vice versa.
    #[test]
    fn test_is_valid_matches_sanitize() {
        let names = [
            "photo.jpg",
            "",
            ".",
            "..",
            "a:b",
            "a/b",
            "a\\b",
            "a\u{0}b",
            "a\u{1f}b",
            "con",
            "con.txt",
            "console",
            "lpt9.tar.gz",
            "trailing.",
            "trailing ",
            "trailing...",
            " leading",
            "Ünïcödé.txt",
            "文件.txt",
            &"a".repeat(255),
            &"a".repeat(256),
        ];

        for rules in [
            Rules::Windows,
            Rules::Hfs,
            Rules::Fat,
            Rules::Posix,
            Rules::Universal,
        ] {
            for name in names {
                assert_eq!(
                    is_valid(name, rules),
                    sanitize(name, rules) == name,
                    "mismatch for {name:?} under {rules:?}"
                );
            }
        }
    }
}
