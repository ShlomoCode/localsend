use flutter_rust_bridge::frb;
use localsend::util::filename;
use std::path::Path;

/// Rewrites `name` into a file name that is legal on the current platform,
/// replacing illegal characters with `_`.
#[frb(sync)]
pub fn sanitize_file_name(name: String) -> String {
    filename::sanitize(&name, filename::Rules::current())
}

/// Sanitizes a received name for its actual parent directory. Opaque Android
/// destinations have no inspectable filesystem, so they use conservative rules.
#[frb(sync)]
pub fn sanitize_file_name_for_directory(
    name: String,
    directory: String,
    counter: Option<u32>,
    conservative: bool,
) -> String {
    let rules = if conservative || directory.starts_with("content://") {
        filename::Rules::Universal
    } else {
        filename::rules_for_directory(Path::new(&directory))
    };

    match counter {
        Some(counter) => filename::sanitize_numbered(&name, rules, counter),
        None => filename::sanitize(&name, rules),
    }
}

/// Whether `name` is a legal file name on the current platform, i.e. whether
/// [sanitize_file_name] would leave it untouched.
#[frb(sync)]
pub fn is_valid_file_name(name: String) -> bool {
    filename::is_valid(&name, filename::Rules::current())
}
