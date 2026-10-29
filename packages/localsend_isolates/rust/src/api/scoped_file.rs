use localsend::model::scoped_file::{ScopedDirectory, ScopedFile};
use localsend::model::transfer::FileMetadata;
use std::{io, sync::Arc};

pub struct RsScopedFile {
    pub directory_path: String,
    pub access_token: String,
    pub relative_path: String,
}

impl RsScopedFile {
    pub(crate) fn acquire(self) -> io::Result<ScopedFile> {
        Ok(ScopedFile {
            directory: acquire_directory(self.directory_path, self.access_token)?,
            relative_path: self.relative_path.into(),
        })
    }
}

pub struct RsScopedEntry {
    pub relative_path: String,
    pub size: u64,
    pub metadata: Option<FileMetadata>,
}

fn acquire_directory(directory_path: String, access_token: String) -> io::Result<ScopedDirectory> {
    let lease = native::retain(&access_token, &directory_path)?;
    Ok(ScopedDirectory {
        path: directory_path.into(),
        lease,
    })
}

pub async fn list_scoped_directory(
    directory_path: String,
    access_token: String,
) -> anyhow::Result<Vec<RsScopedEntry>> {
    let directory = acquire_directory(directory_path, access_token)?;
    Ok(
        localsend::model::scoped_file::list_scoped_directory(directory)
            .await?
            .into_iter()
            .map(|entry| RsScopedEntry {
                relative_path: entry.relative_path.to_string_lossy().into_owned(),
                size: entry.size,
                metadata: entry.metadata,
            })
            .collect(),
    )
}

pub async fn read_scoped_text_file(file: RsScopedFile) -> anyhow::Result<String> {
    Ok(localsend::model::scoped_file::read_scoped_text_file(file.acquire()?).await?)
}

#[cfg(target_os = "ios")]
mod native {
    use super::*;
    use std::ffi::CString;

    type Retain = unsafe extern "C" fn(*const libc::c_char, *const libc::c_char) -> bool;
    type Release = unsafe extern "C" fn(*const libc::c_char);

    struct Lease {
        token: CString,
        release: Release,
    }
    impl Drop for Lease {
        fn drop(&mut self) {
            // SAFETY: successful native retain owns exactly one reference.
            unsafe { (self.release)(self.token.as_ptr()) };
        }
    }

    fn symbols() -> io::Result<(Retain, Release)> {
        // RTLD_DEFAULT searches the linked app image. Resolve both functions
        // before retaining, so a missing release cannot leak a reference.
        let retain = unsafe {
            libc::dlsym(
                libc::RTLD_DEFAULT,
                c"localsend_directory_access_retain_v1".as_ptr(),
            )
        };
        let release = unsafe {
            libc::dlsym(
                libc::RTLD_DEFAULT,
                c"localsend_directory_access_release_v1".as_ptr(),
            )
        };
        if retain.is_null() || release.is_null() {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Directory access bridge is unavailable",
            ));
        }
        // SAFETY: the versioned C ABI declarations match the app registry header.
        Ok((
            unsafe { std::mem::transmute::<*mut libc::c_void, Retain>(retain) },
            unsafe { std::mem::transmute::<*mut libc::c_void, Release>(release) },
        ))
    }

    pub(super) fn retain(token: &str, path: &str) -> io::Result<Arc<dyn Send + Sync>> {
        let token = CString::new(token).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid directory access token",
            )
        })?;
        let path = CString::new(path)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Invalid directory path"))?;
        let (retain, release) = symbols()?;
        // SAFETY: both NUL-terminated strings live for this synchronous call.
        if !unsafe { retain(token.as_ptr(), path.as_ptr()) } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Directory access expired; select the directory again",
            ));
        }
        Ok(Arc::new(Lease { token, release }))
    }
}

#[cfg(not(target_os = "ios"))]
mod native {
    use super::*;
    pub(super) fn retain(_: &str, _: &str) -> io::Result<Arc<dyn Send + Sync>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Scoped directory access is available only on iOS",
        ))
    }
}
