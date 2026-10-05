//! Filename handling for untrusted, peer-supplied names.

use icu_properties::{props::GeneralCategory, CodePointMapData};
#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

const FALLBACK_LIMIT: usize = 255;
const MIN_TRUNCATED_STEM: usize = 5;
const ILLEGAL_ASCII: &str = "\"*/:<>?\\|";
const RESERVED_WINDOWS_NAMES: &[&str] = &[
    "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
    "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
];

/// Rules that affect the encoding budget and Windows device names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rules {
    Windows,
    Posix,
    /// Conservative policy for paths supplied by opaque document providers.
    Universal,
}

impl Rules {
    pub const fn current() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else if cfg!(unix) {
            Self::Posix
        } else {
            Self::Universal
        }
    }

    fn units(self, value: &str) -> usize {
        match self {
            Self::Windows => value.encode_utf16().count(),
            _ => value.len(),
        }
    }

    fn windows_names(self) -> bool {
        matches!(self, Self::Windows | Self::Universal)
    }
}

/// Component limit queried from the destination volume, in UTF-16 units on
/// Windows and UTF-8 bytes elsewhere.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Policy {
    pub rules: Rules,
    pub max_len: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum FilenameError {
    #[error("filename extension and minimum basename exceed the destination limit")]
    InsufficientSpace,
}

/// Find the nearest existing directory before querying the actual component
/// limit. A failed query uses a conservative 255-byte budget.
pub fn rules_for_directory(directory: &Path) -> Policy {
    let absolute = if directory.is_absolute() {
        directory.to_path_buf()
    } else {
        match std::env::current_dir() {
            Ok(cwd) => cwd.join(directory),
            Err(_) => {
                return Policy {
                    rules: Rules::Universal,
                    max_len: FALLBACK_LIMIT,
                }
            }
        }
    };
    let queried = absolute
        .ancestors()
        .find(|ancestor| ancestor.is_dir())
        .and_then(query_component_limit)
        .filter(|limit| *limit > 0);
    let (rules, max_len) = match queried {
        Some(limit) => (Rules::current(), limit),
        None => (Rules::Universal, FALLBACK_LIMIT),
    };
    #[cfg(windows)]
    let max_len = {
        // Win32's ordinary full-path limit includes the terminator. Reserve
        // the actual intended directory prefix even when only its ancestor exists.
        let prefix = absolute.as_os_str().encode_wide().count() + 1;
        max_len.min(259usize.saturating_sub(prefix))
    };
    Policy { rules, max_len }
}

#[cfg(unix)]
fn query_component_limit(directory: &Path) -> Option<usize> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let path = CString::new(directory.as_os_str().as_bytes()).ok()?;
    // POSIX pathconf(_PC_NAME_MAX) queries the selected directory's volume.
    // https://pubs.opengroup.org/onlinepubs/9799919799/functions/pathconf.html
    // SAFETY: `path` is NUL-terminated and remains alive for the call.
    let limit = unsafe { libc::pathconf(path.as_ptr(), libc::_PC_NAME_MAX) };
    (limit > 0).then_some(limit as usize)
}

#[cfg(windows)]
fn query_component_limit(directory: &Path) -> Option<usize> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "kernel32")]
    extern "system" {
        fn GetVolumePathNameW(path: *const u16, volume: *mut u16, length: u32) -> i32;
        fn GetVolumeInformationW(
            root: *const u16,
            name: *mut u16,
            name_length: u32,
            serial: *mut u32,
            maximum: *mut u32,
            flags: *mut u32,
            filesystem: *mut u16,
            filesystem_length: u32,
        ) -> i32;
    }
    // These APIs resolve nested volume mount points and return that volume's
    // maximumComponentLength rather than assuming NTFS's common value.
    // https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumeinformationw
    let mut path: Vec<u16> = directory.as_os_str().encode_wide().collect();
    path.push(0);
    let mut volume = vec![0u16; 32768];
    // SAFETY: `path` is NUL-terminated; `volume` is a writable UTF-16 buffer.
    if unsafe { GetVolumePathNameW(path.as_ptr(), volume.as_mut_ptr(), volume.len() as u32) } == 0 {
        return None;
    }
    let mut maximum = 0;
    // SAFETY: the successful volume query wrote a NUL-terminated root; the
    // maximum pointer is valid and optional output pointers are null.
    if unsafe {
        GetVolumeInformationW(
            volume.as_ptr(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            &mut maximum,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
        )
    } == 0
    {
        return None;
    }
    (maximum > 0).then_some(maximum as usize)
}

#[cfg(not(any(unix, windows)))]
fn query_component_limit(_directory: &Path) -> Option<usize> {
    None
}

#[derive(Debug, Clone, Copy)]
pub struct Options<'a> {
    pub replacement: &'a str,
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

pub fn sanitize(name: &str, rules: Rules) -> Result<String, FilenameError> {
    sanitize_with(name, rules, &Options::default())
}

pub fn sanitize_numbered(name: &str, rules: Rules, counter: u32) -> Result<String, FilenameError> {
    sanitize_impl(
        name,
        Policy {
            rules,
            max_len: FALLBACK_LIMIT,
        },
        Some(counter),
        &Options::default(),
    )
}

pub fn sanitize_with(name: &str, rules: Rules, options: &Options) -> Result<String, FilenameError> {
    sanitize_impl(
        name,
        Policy {
            rules,
            max_len: FALLBACK_LIMIT,
        },
        None,
        options,
    )
}

/// Sanitize against the actual destination. `counter` is inserted before the
/// extension and counted before shortening. Use `conservative` for opaque
/// providers whose destination path cannot be queried meaningfully.
pub fn sanitize_for_directory(
    name: &str,
    directory: &Path,
    counter: Option<u32>,
    conservative: bool,
) -> Result<String, FilenameError> {
    let policy = if conservative {
        Policy {
            rules: Rules::Universal,
            max_len: FALLBACK_LIMIT,
        }
    } else {
        rules_for_directory(directory)
    };
    sanitize_impl(name, policy, counter, &Options::default())
}

/// Chromium's `TruncateFilename` keeps the extension and at least five native
/// units of basename when a name needs shortening. The counter occupies part
/// of that basename budget. Our Unix input is already UTF-8, so truncation can
/// preserve a character boundary; Chromium's generic POSIX FilePath cannot
/// assume that encoding. LocalSend writes final names directly, so it needs no
/// temporary .crdownload or :Zone.Identifier reservation.
/// https://chromium.googlesource.com/chromium/src/+/e7e371aa7a6adf445cc773f6fae73a52d5c795f0/components/filename_generation/filename_generation.cc#152
fn sanitize_impl(
    name: &str,
    policy: Policy,
    counter: Option<u32>,
    options: &Options,
) -> Result<String, FilenameError> {
    let rules = policy.rules;
    let mut prepared = prepare_generated_name(name, rules);
    if prepared.is_empty() || prepared.chars().all(|c| c == '-' || c == '_') {
        prepared = prepare_generated_name(options.placeholder, rules);
    }
    let cleaned = replace_illegal(&prepared, rules, options.replacement);
    let suffix = counter
        .map(|value| format!(" ({value})"))
        .unwrap_or_default();
    let (stem, extension) = split_extension(&cleaned, rules);
    let required = rules.units(&suffix) + rules.units(extension) + MIN_TRUNCATED_STEM;
    let mut candidate = format!("{stem}{suffix}{extension}");
    if rules.units(&candidate) > policy.max_len {
        if required > policy.max_len {
            return Err(FilenameError::InsufficientSpace);
        }
        let budget = policy.max_len - rules.units(&suffix) - rules.units(extension);
        let stem = truncate_units(stem, rules, budget);
        if rules.units(stem) < MIN_TRUNCATED_STEM {
            return Err(FilenameError::InsufficientSpace);
        }
        candidate = format!("{stem}{suffix}{extension}");
    }
    // Truncation may expose an illegal endpoint (for example a space just
    // before the cut); repair it without changing the protected extension.
    if let Some(end) = candidate.chars().last() {
        if is_illegal_at_end(end) {
            candidate.replace_range(candidate.len() - end.len_utf8().., "_");
        }
    }
    Ok(candidate)
}

/// Mirrors the generated-name prepass in Chromium's filename_util_internal.cc:
/// Windows preserves the number of trimmed endpoint characters as underscores;
/// all platforms remove leading/trailing dots before ICU character replacement.
/// https://chromium.googlesource.com/chromium/src/+/e7e371aa7a6adf445cc773f6fae73a52d5c795f0/net/base/filename_util_internal.cc#79
fn prepare_generated_name(name: &str, rules: Rules) -> String {
    let mut prepared = name.to_string();
    if rules.windows_names() {
        let trimmed = prepared
            .trim_end_matches(|c: char| c == '.' || c.is_whitespace())
            .len();
        let removed = prepared[trimmed..].chars().count();
        prepared.truncate(trimmed);
        prepared.extend(std::iter::repeat('_').take(removed));
    }
    prepared.trim_matches('.').to_string()
}

fn replace_illegal(name: &str, rules: Rules, replacement: &str) -> String {
    let categories = CodePointMapData::<GeneralCategory>::new();
    let could_be_short = rules.windows_names() && could_be_short_name(name);
    let chars: Vec<char> = name.chars().collect();
    let mut result = String::with_capacity(name.len());
    for (index, &c) in chars.iter().enumerate() {
        let category = categories.get(c);
        let noncharacter =
            (0xFDD0..=0xFDEF).contains(&(c as u32)) || ((c as u32) & 0xFFFE == 0xFFFE);
        if ILLEGAL_ASCII.contains(c)
            || matches!(category, GeneralCategory::Control | GeneralCategory::Format)
            || noncharacter
            || (could_be_short && c == '~')
            || ((index == 0 || index + 1 == chars.len()) && is_illegal_at_end(c))
        {
            result.push_str(replacement);
        } else {
            result.push(c);
        }
    }
    if result.is_empty() {
        return result;
    }
    if rules.windows_names() && reserved_windows_name(&result) {
        result.insert(0, '_');
    }
    result
}

fn is_illegal_at_end(c: char) -> bool {
    c == '.' || c == '~' || c.is_whitespace()
}

fn could_be_short_name(name: &str) -> bool {
    if !name.contains('~') || name.encode_utf16().count() > 12 {
        return false;
    }
    let mut parts = name.split('.');
    let stem = parts.next().unwrap_or("");
    let extension = parts.next();
    if parts.next().is_some()
        || stem.is_empty()
        || stem.encode_utf16().count() > 8
        || extension.is_some_and(|ext| ext.encode_utf16().count() > 3)
    {
        return false;
    }
    !name
        .chars()
        .any(|c| c.is_whitespace() || "\"/[]:+|<>=;?,*\\".contains(c))
}

fn reserved_windows_name(name: &str) -> bool {
    // Chromium's DOS device names also reserve CLOCK$ by stem, while the
    // four shell-sensitive magic names below match only the entire filename.
    // https://chromium.googlesource.com/chromium/src/+/e7e371aa7a6adf445cc773f6fae73a52d5c795f0/base/files/file_util.cc#541
    let stem = name.split('.').next().unwrap_or(name);
    let reserved_device = RESERVED_WINDOWS_NAMES
        .iter()
        .any(|reserved| stem.eq_ignore_ascii_case(reserved));
    reserved_device
        || stem.eq_ignore_ascii_case("clock$")
        || ["desktop.ini", "thumbs.db", "conin$", "conout$"]
            .iter()
            .any(|reserved| name.eq_ignore_ascii_case(reserved))
}

fn split_extension(name: &str, rules: Rules) -> (&str, &str) {
    // FilePath::Extension combines a 1–4 native-unit penultimate component
    // with a recognized compressed suffix, or the exact `user.js` pair.
    // https://chromium.googlesource.com/chromium/src/+/e7e371aa7a6adf445cc773f6fae73a52d5c795f0/base/files/file_path.cc#54
    const COMPRESSED: &[&str] = &["bz", "bz2", "gz", "lz", "lzma", "lzo", "xz", "z", "zst"];
    let Some(last) = name
        .rfind('.')
        .filter(|&index| index > 0 && index + 1 < name.len())
    else {
        return (name, "");
    };
    if let Some(previous) = name[..last].rfind('.').filter(|&index| index > 0) {
        let penultimate = &name[previous + 1..last];
        let final_component = &name[last + 1..];
        if (1..=4).contains(&rules.units(penultimate))
            && (COMPRESSED
                .iter()
                .any(|suffix| final_component.eq_ignore_ascii_case(suffix))
                || (penultimate.eq_ignore_ascii_case("user")
                    && final_component.eq_ignore_ascii_case("js")))
        {
            return (&name[..previous], &name[previous..]);
        }
    }
    (&name[..last], &name[last..])
}

fn truncate_units(name: &str, rules: Rules, budget: usize) -> &str {
    let mut used = 0;
    for (index, c) in name.char_indices() {
        let size = match rules {
            Rules::Windows => c.len_utf16(),
            _ => c.len_utf8(),
        };
        if used + size > budget {
            return &name[..index];
        }
        used += size;
    }
    name
}

pub fn is_valid(name: &str, rules: Rules) -> bool {
    if name.is_empty() || name == "." || name == ".." || rules.units(name) > FALLBACK_LIMIT {
        return false;
    }
    sanitize(name, rules).is_ok_and(|cleaned| cleaned == name)
}

/// Return the last meaningful segment of a peer-supplied path.
pub fn final_component(path: &str) -> &str {
    path.rsplit(['/', '\\'])
        .find(|part| !part.is_empty() && *part != "." && *part != "..")
        .unwrap_or("")
}

pub fn sanitize_path(path: &str, rules: Rules) -> Result<String, FilenameError> {
    sanitize(final_component(path), rules)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reported_japanese_posix_name_keeps_mp4_extension_when_shortened() {
        let name = "土曜のあさはほめるちゃん 20260926 ＃124「関西のいま気になるエリアのええところ“ほめるポイント＝ほめポ”を見つけながら、ぶらりするほっこりトークがたっぷりのほめぶら番組！今回は、“グラングリーン大阪”をぶらり！」.mp4";
        assert_eq!(name.len(), 314);
        assert_eq!(name.encode_utf16().count(), 116);
        assert_eq!(sanitize(name, Rules::Windows).unwrap(), name);
        let shortened = sanitize(name, Rules::Posix).unwrap();
        assert!(shortened.ends_with(".mp4"));
        assert!(shortened.len() <= 255);
    }

    #[test]
    fn emoji_and_collision_fit_without_splitting_extension() {
        let name = format!("{}😀.tar.gz", "a".repeat(245));
        let numbered = sanitize_numbered(&name, Rules::Posix, 12).unwrap();
        assert!(numbered.ends_with(" (12).tar.gz"));
        assert!(numbered.len() <= 255);
        assert!(std::str::from_utf8(numbered.as_bytes()).is_ok());

        let windows_at_limit = format!("{}😀.mp4", "a".repeat(249));
        assert!(windows_at_limit.len() > 255);
        assert_eq!(windows_at_limit.encode_utf16().count(), 255);
        assert_eq!(
            sanitize(&windows_at_limit, Rules::Windows).unwrap(),
            windows_at_limit
        );
        let windows_over_limit = format!("{}😀.mp4", "a".repeat(250));
        let shortened = sanitize(&windows_over_limit, Rules::Windows).unwrap();
        assert_eq!(shortened, format!("{}.mp4", "a".repeat(250)));
        assert_eq!(shortened.encode_utf16().count(), 254);

        let compound = format!("{}.FoO.ZST", "a".repeat(250));
        let numbered_compound = sanitize_numbered(&compound, Rules::Posix, 1).unwrap();
        assert!(numbered_compound.ends_with(" (1).FoO.ZST"));
        let user_script = format!("{}.user.js", "a".repeat(250));
        assert!(sanitize_numbered(&user_script, Rules::Posix, 1)
            .unwrap()
            .ends_with(" (1).user.js"));
        assert_eq!(
            sanitize_numbered("a.longname.zst", Rules::Posix, 1).unwrap(),
            "a.longname (1).zst"
        );
        assert_eq!(
            sanitize_numbered("a.tar.bz", Rules::Posix, 1).unwrap(),
            "a (1).tar.bz"
        );
    }

    #[test]
    fn shared_illegal_set_and_platform_reserved_names() {
        assert_eq!(
            sanitize("a\u{200d}b\u{fdd0}c", Rules::Posix).unwrap(),
            "a_b_c"
        );
        assert_eq!(sanitize("a:b?c|d", Rules::Posix).unwrap(), "a_b_c_d");
        assert_eq!(sanitize("CON.txt", Rules::Windows).unwrap(), "_CON.txt");
        assert_eq!(sanitize("CON.txt", Rules::Posix).unwrap(), "CON.txt");
        assert_eq!(sanitize("a~1.txt", Rules::Windows).unwrap(), "a_1.txt");
        assert_eq!(sanitize("a~1.txt", Rules::Posix).unwrap(), "a~1.txt");
        assert_eq!(
            sanitize("CLOCK$.txt", Rules::Windows).unwrap(),
            "_CLOCK$.txt"
        );
        assert_eq!(
            sanitize("desktop.ini", Rules::Windows).unwrap(),
            "_desktop.ini"
        );
        assert_eq!(sanitize("thumbs.db", Rules::Windows).unwrap(), "_thumbs.db");
        assert_eq!(sanitize("conin$", Rules::Windows).unwrap(), "_conin$");
        assert_eq!(sanitize("conout$", Rules::Windows).unwrap(), "_conout$");
        assert_eq!(
            sanitize("conin$.txt", Rules::Windows).unwrap(),
            "conin$.txt"
        );
        assert_eq!(
            sanitize("desktop.ini.txt", Rules::Windows).unwrap(),
            "desktop.ini.txt"
        );
    }

    #[test]
    fn tiny_budget_reports_impossible_extension() {
        let policy = Policy {
            rules: Rules::Posix,
            max_len: 8,
        };
        assert_eq!(
            sanitize_impl("longname.mp4", policy, None, &Options::default()),
            Err(FilenameError::InsufficientSpace)
        );
        assert_eq!(
            sanitize_impl("abcdefghi", policy, None, &Options::default()).unwrap(),
            "abcdefgh"
        );
        let collision = Policy {
            rules: Rules::Posix,
            max_len: 12,
        };
        assert_eq!(
            sanitize_impl("longname.mp4", collision, Some(2), &Options::default()),
            Err(FilenameError::InsufficientSpace)
        );
    }

    #[test]
    fn queries_existing_and_missing_nested_directory() {
        let existing = std::env::temp_dir();
        let nested = existing
            .join(format!("localsend-missing-{}", std::process::id()))
            .join("nested");
        assert_eq!(
            rules_for_directory(&existing).max_len,
            rules_for_directory(&nested).max_len
        );
        assert!(rules_for_directory(&existing).max_len > 0);
    }

    #[test]
    fn path_component_and_endpoint_rules() {
        assert_eq!(final_component("../folder/photo.jpg"), "photo.jpg");
        assert_eq!(
            sanitize_path("../folder/photo.jpg", Rules::Posix).unwrap(),
            "photo.jpg"
        );
        assert_eq!(sanitize(".hidden", Rules::Posix).unwrap(), "hidden");
        assert_eq!(sanitize("file.", Rules::Posix).unwrap(), "file");
        assert_eq!(sanitize("...", Rules::Posix).unwrap(), "untitled");
        assert_eq!(sanitize("---", Rules::Posix).unwrap(), "untitled");
        assert_eq!(sanitize("file.", Rules::Windows).unwrap(), "file_");
        assert_eq!(
            sanitize("evil.exe. ", Rules::Windows).unwrap(),
            "evil.exe__"
        );
        assert_eq!(sanitize(".hidden", Rules::Windows).unwrap(), "hidden");
        assert_eq!(sanitize(" file ", Rules::Posix).unwrap(), "_file_");
    }
}
