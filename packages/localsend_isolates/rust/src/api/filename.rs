use anyhow::Result;
use flutter_rust_bridge::frb;
use localsend::util::filename;
use std::path::Path;

/// Applies the shared filename policy with the current platform's default limit.
#[frb(sync)]
pub fn sanitize_file_name(name: String) -> Result<String> {
    Ok(filename::sanitize(&name, filename::Rules::current())?)
}

/// Sanitizes a received name using its parent directory's component and path
/// limits. Opaque storage providers use the conservative default limit.
#[frb(sync)]
pub fn sanitize_file_name_for_directory(
    name: String,
    directory: String,
    counter: Option<u32>,
    conservative: bool,
) -> Result<String> {
    Ok(filename::sanitize_for_directory(
        &name,
        Path::new(&directory),
        counter,
        conservative || directory.starts_with("content://"),
    )?)
}

/// Whether `name` is a legal file name on the current platform, i.e. whether
/// [sanitize_file_name] would leave it untouched.
#[frb(sync)]
pub fn is_valid_file_name(name: String) -> bool {
    filename::is_valid(&name, filename::Rules::current())
}
