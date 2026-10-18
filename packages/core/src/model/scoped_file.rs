//! Files selected through an Apple directory document picker.
//!
//! The caller retains the original picker grant. Its owned guard stays alive
//! through each synchronous coordinated accessor, including on cancellation.
use super::transfer::{FileMetadata, FileStream};
use std::{
    io,
    path::{Component, Path, PathBuf},
    sync::Arc,
};

#[derive(Clone)]
pub struct ScopedFile {
    pub directory: ScopedDirectory,
    pub relative_path: PathBuf,
}

/// An opaque, caller-owned lease and the matching picker directory path.
/// The core never interprets the lease or starts/stops security scope itself.
#[derive(Clone)]
pub struct ScopedDirectory {
    pub path: PathBuf,
    pub lease: Arc<dyn Send + Sync>,
}

impl std::fmt::Debug for ScopedDirectory {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ScopedDirectory")
            .field("path", &self.path)
            .finish()
    }
}

impl std::fmt::Debug for ScopedFile {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ScopedFile")
            .field("relative_path", &self.relative_path)
            .field("directory", &self.directory)
            .finish()
    }
}

#[derive(Debug, Clone)]
pub struct ScopedEntry {
    pub relative_path: PathBuf,
    pub size: u64,
    pub metadata: Option<FileMetadata>,
}

fn validate_relative_path(path: &Path) -> io::Result<()> {
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Expected a relative file path without parent components",
        ));
    }
    Ok(())
}

/// Lists regular files recursively, rejecting symbolic links.
/// Provider and permission errors fail selection instead of silently omitting files.
pub async fn list_scoped_directory(directory: ScopedDirectory) -> io::Result<Vec<ScopedEntry>> {
    blocking(move || platform::list(directory)).await
}

/// Reads an ignore file using the same scope and coordination as transfers.
pub async fn read_scoped_text_file(file: ScopedFile) -> io::Result<String> {
    validate_relative_path(&file.relative_path)?;
    blocking(move || platform::read_text(file)).await
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> io::Result<T> + Send + 'static,
) -> io::Result<T> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(io::Error::other)?
}

pub(super) fn into_stream(file: ScopedFile) -> FileStream {
    platform::stream(file)
}

#[cfg(not(target_vendor = "apple"))]
mod platform {
    use super::*;
    fn unsupported() -> io::Error {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "Apple scoped files are unavailable on this platform",
        )
    }
    pub(super) fn list(_: ScopedDirectory) -> io::Result<Vec<ScopedEntry>> {
        Err(unsupported())
    }
    pub(super) fn read_text(_: ScopedFile) -> io::Result<String> {
        Err(unsupported())
    }
    pub(super) fn stream(_: ScopedFile) -> FileStream {
        Box::pin(futures_util::stream::once(async { Err(unsupported()) }))
    }
}

#[cfg(target_vendor = "apple")]
mod platform {
    use super::super::transfer::{FILE_CHANNEL_CAPACITY, READ_BUFFER_SIZE};
    use super::*;
    use block2::StackBlock;
    use bytes::Bytes;
    use futures_util::Stream;
    use objc2::{
        rc::{autoreleasepool, Retained},
        AnyThread,
    };
    use objc2_foundation::{
        NSError, NSFileCoordinator, NSFileCoordinatorReadingOptions, NSString, NSURL,
    };
    use std::{
        cell::RefCell,
        ffi::CStr,
        io::Read,
        os::unix::ffi::OsStrExt,
        pin::Pin,
        ptr::NonNull,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc, Mutex,
        },
        task::{Context, Poll},
    };
    use tokio::sync::mpsc;

    fn root_url(directory: &ScopedDirectory) -> io::Result<Retained<NSURL>> {
        let path = directory.path.to_str().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Scoped directory path is not UTF-8",
            )
        })?;
        Ok(NSURL::fileURLWithPath_isDirectory(&NSString::from_str(path), true))
    }
    fn child(root: &NSURL, path: &Path) -> io::Result<Retained<NSURL>> {
        validate_relative_path(path)?;
        let path = path.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Scoped path is not UTF-8")
        })?;
        root.URLByAppendingPathComponent(&NSString::from_str(path))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Cannot construct scoped child URL",
                )
            })
    }
    fn foundation_error(error: Retained<NSError>) -> io::Error {
        let kind = if error.domain().to_string() == "NSCocoaErrorDomain" {
            match error.code() {
                4 | 260 => io::ErrorKind::NotFound,
                257 => io::ErrorKind::PermissionDenied,
                3072 => io::ErrorKind::Interrupted,
                _ => io::ErrorKind::Other,
            }
        } else {
            io::ErrorKind::Other
        };
        io::Error::new(kind, error.localizedDescription().to_string())
    }
    fn url_path(url: &NSURL) -> PathBuf {
        // SAFETY: Foundation returns a NUL-terminated representation valid
        // while url lives. Copy it before returning.
        let bytes = unsafe { CStr::from_ptr(url.fileSystemRepresentation().as_ptr()) }.to_bytes();
        Path::new(std::ffi::OsStr::from_bytes(bytes)).to_owned()
    }

    // Apple permits -cancel from any thread while coordination is pending.
    // This wrapper exposes only cancel; all other coordinator operations stay
    // on the producer thread, and the retain keeps the object alive.
    struct CancelCoordinator(Retained<NSFileCoordinator>);
    unsafe impl Send for CancelCoordinator {}
    unsafe impl Sync for CancelCoordinator {}
    impl CancelCoordinator {
        fn cancel(&self) {
            self.0.cancel();
        }
    }
    #[derive(Default)]
    struct Cancellation {
        cancelled: AtomicBool,
        coordinator: Mutex<Option<CancelCoordinator>>,
        notification: tokio::sync::Notify,
    }
    impl Cancellation {
        fn cancel(&self) {
            self.cancelled.store(true, Ordering::Release);
            self.notification.notify_one();
            self.cancel_pending();
        }
        fn cancel_pending(&self) {
            autoreleasepool(|_| {
                if let Some(coordinator) = self.coordinator.lock().unwrap().as_ref() {
                    coordinator.cancel();
                }
            });
        }
        fn check(&self) -> io::Result<()> {
            if self.cancelled.load(Ordering::Acquire) {
                Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Scoped read cancelled",
                ))
            } else {
                Ok(())
            }
        }
    }
    fn coordinate<T>(
        url: &NSURL,
        cancellation: &Cancellation,
        read: impl FnOnce(&Path) -> io::Result<T>,
    ) -> io::Result<T> {
        cancellation.check()?;
        let coordinator =
            NSFileCoordinator::initWithFilePresenter(NSFileCoordinator::alloc(), None);
        *cancellation.coordinator.lock().unwrap() = Some(CancelCoordinator(coordinator.clone()));
        cancellation.check()?;
        let result = RefCell::new(None);
        let read = RefCell::new(Some(read));
        let block = StackBlock::new(|url: NonNull<NSURL>| {
            // SAFETY: synchronous accessor receives a live Foundation NSURL.
            let path = url_path(unsafe { url.as_ref() });
            let value = cancellation
                .check()
                .and_then(|_| read.borrow_mut().take().unwrap()(&path));
            *result.borrow_mut() = Some(value);
        });
        let mut error = None;
        coordinator.coordinateReadingItemAtURL_options_error_byAccessor(
            url,
            NSFileCoordinatorReadingOptions::empty(),
            Some(&mut error),
            &block,
        );
        cancellation.coordinator.lock().unwrap().take();
        if let Some(error) = error {
            return Err(foundation_error(error));
        }
        result
            .into_inner()
            .unwrap_or_else(|| Err(io::Error::other("File coordinator did not provide access")))
    }

    // Reject directory symlinks as well as file symlinks, avoiding escape and
    // recursive loops. These checks run inside coordinated access.
    fn reject_symlinks(root: &Path, relative: &Path) -> io::Result<()> {
        let mut path = root.to_owned();
        for component in relative.components() {
            path.push(component);
            if std::fs::symlink_metadata(&path)?.file_type().is_symlink() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Symbolic links are not supported in scoped directories",
                ));
            }
        }
        Ok(())
    }
    fn with_file<T>(
        file: &ScopedFile,
        cancellation: &Cancellation,
        read: impl FnOnce(&Path) -> io::Result<T>,
    ) -> io::Result<T> {
        validate_relative_path(&file.relative_path)?;
        // The worker owns `file`, so its lease outlives the coordinator and
        // synchronous accessor even when the consumer drops the stream.
        let root = root_url(&file.directory)?;
        let url = child(&root, &file.relative_path)?;
        coordinate(&url, cancellation, |path| {
            reject_symlinks(&url_path(&root), &file.relative_path)?;
            read(path)
        })
    }
    pub(super) fn read_text(file: ScopedFile) -> io::Result<String> {
        autoreleasepool(|_| {
            with_file(&file, &Cancellation::default(), |path| {
                let mut text = String::new();
                open_file(path)?.read_to_string(&mut text)?;
                Ok(text)
            })
        })
    }
    fn open_file(path: &Path) -> io::Result<std::fs::File> {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
    }
    pub(super) fn list(directory: ScopedDirectory) -> io::Result<Vec<ScopedEntry>> {
        autoreleasepool(|_| {
            let root = root_url(&directory)?;
            let cancellation = Cancellation::default();
            let mut pending = vec![PathBuf::new()];
            let mut files = Vec::new();
            while let Some(relative) = pending.pop() {
                let url = if relative.as_os_str().is_empty() {
                    root.clone()
                } else {
                    child(&root, &relative)?
                };
                let children = coordinate(&url, &cancellation, |directory| {
                    if !relative.as_os_str().is_empty() {
                        reject_symlinks(&url_path(&root), &relative)?;
                    }
                    std::fs::read_dir(directory)?
                        .map(|entry| {
                            let entry = entry?;
                            Ok((entry.file_name(), entry.file_type()?))
                        })
                        .collect::<io::Result<Vec<_>>>()
                })?;
                for (name, kind) in children {
                    let path = relative.join(name);
                    if kind.is_symlink() {
                        return Err(io::Error::new(
                            io::ErrorKind::Unsupported,
                            format!(
                                "Symbolic links in scoped directories are not supported: {}",
                                path.display()
                            ),
                        ));
                    }
                    if kind.is_dir() {
                        pending.push(path);
                    } else if kind.is_file() {
                        let url = child(&root, &path)?;
                        let metadata = coordinate(&url, &cancellation, |coordinated_path| {
                            reject_symlinks(&url_path(&root), &path)?;
                            let metadata = std::fs::symlink_metadata(coordinated_path)?;
                            if !metadata.is_file() {
                                return Err(io::Error::new(
                                    io::ErrorKind::Unsupported,
                                    "Scoped item is no longer a regular file",
                                ));
                            }
                            Ok(metadata)
                        })?;
                        files.push(ScopedEntry {
                            relative_path: path,
                            size: metadata.len(),
                            metadata: FileMetadata::from_fs_metadata(&metadata),
                        });
                    } else {
                        return Err(io::Error::new(
                            io::ErrorKind::Unsupported,
                            format!(
                                "Scoped item is not a regular file or directory: {}",
                                path.display()
                            ),
                        ));
                    }
                }
            }
            Ok(files)
        })
    }

    struct ScopedStream {
        receiver: mpsc::Receiver<io::Result<Bytes>>,
        cancellation: Arc<Cancellation>,
    }
    impl Stream for ScopedStream {
        type Item = io::Result<Bytes>;
        fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
            self.receiver.poll_recv(cx)
        }
    }
    impl Drop for ScopedStream {
        fn drop(&mut self) {
            // Wake the backpressured producer before cancelling coordination.
            // Scope ownership stays with the producer until its accessor exits.
            self.receiver.close();
            self.cancellation.cancel();
        }
    }
    fn read_chunks(
        mut reader: impl Read,
        sender: &mpsc::Sender<io::Result<Bytes>>,
        cancellation: &Cancellation,
    ) -> io::Result<()> {
        let mut buffer = vec![0_u8; READ_BUFFER_SIZE];
        loop {
            cancellation.check()?;
            let size = reader.read(&mut buffer)?;
            if size == 0 {
                return Ok(());
            }
            if sender
                .blocking_send(Ok(Bytes::copy_from_slice(&buffer[..size])))
                .is_err()
            {
                return Ok(());
            }
        }
    }
    pub(super) fn stream(file: ScopedFile) -> FileStream {
        let (sender, receiver) = mpsc::channel(FILE_CHANNEL_CAPACITY);
        let cancellation = Arc::new(Cancellation::default());
        let worker_cancellation = cancellation.clone();
        let mut worker = tokio::task::spawn_blocking(move || {
            autoreleasepool(|_| {
                let result = with_file(&file, &worker_cancellation, |path| {
                    let reader = open_file(path)?;
                    read_chunks(reader, &sender, &worker_cancellation)
                });
                if let Err(error) = result {
                    let _ = sender.blocking_send(Err(error));
                }
            })
        });
        let monitor = cancellation.clone();
        tokio::spawn(async move {
            tokio::select! {
                _ = &mut worker => return,
                _ = monitor.notification.notified() => {}
            }
            // Cancellation can race the synchronous call's entry. Retry until
            // the producer exits so a cancellation immediately before entry
            // cannot leave the coordinator waiting for a provider indefinitely.
            loop {
                monitor.cancel_pending();
                tokio::select! {
                    _ = &mut worker => break,
                    _ = tokio::time::sleep(std::time::Duration::from_millis(25)) => {}
                }
            }
        });
        Box::pin(ScopedStream {
            receiver,
            cancellation,
        })
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use futures_util::StreamExt;

        #[cfg(target_os = "macos")]
        mod native_coordination {
            use super::*;
            use objc2::{
                define_class, extern_class, extern_methods, msg_send, runtime::ProtocolObject,
                DefinedClass,
            };
            use objc2_foundation::{NSFilePresenter, NSObject, NSObjectProtocol};
            use std::{sync::mpsc as channel, thread, time::Duration};

            #[test]
            fn lease_survives_cancelled_reader_until_accessor_exits() {
                struct DropSignal(Arc<AtomicBool>);
                impl Drop for DropSignal {
                    fn drop(&mut self) {
                        self.0.store(true, Ordering::Release);
                    }
                }

                let directory =
                    std::env::temp_dir().join(format!("localsend-lease-{}", uuid::Uuid::new_v4()));
                std::fs::create_dir(&directory).unwrap();
                std::fs::write(directory.join("file"), b"content").unwrap();
                let released = Arc::new(AtomicBool::new(false));
                let file = ScopedFile {
                    directory: ScopedDirectory {
                        path: directory.clone(),
                        lease: Arc::new(DropSignal(released.clone())),
                    },
                    relative_path: PathBuf::from("file"),
                };
                let cancellation = Arc::new(Cancellation::default());
                let worker_cancellation = cancellation.clone();
                let (entered_tx, entered_rx) = channel::channel();
                let (leave_tx, leave_rx) = channel::channel();
                let worker = thread::spawn(move || {
                    autoreleasepool(|_| {
                        with_file(&file, &worker_cancellation, |_| {
                            entered_tx.send(()).unwrap();
                            leave_rx.recv().unwrap();
                            Ok(())
                        })
                    })
                });
                if let Err(error) = entered_rx.recv_timeout(Duration::from_secs(5)) {
                    panic!("coordinated accessor did not start ({error:?}): {:?}", worker.join().unwrap());
                }
                cancellation.cancel();
                assert!(!released.load(Ordering::Acquire));
                leave_tx.send(()).unwrap();
                let _ = worker.join().unwrap();
                assert!(released.load(Ordering::Acquire));
                std::fs::remove_dir_all(directory).unwrap();
            }

            // NSOperation is not enabled in the release Foundation feature set.
            // This test-only binding names the genuine Foundation queue class.
            extern_class!(
                #[unsafe(super(NSObject))]
                #[name = "NSOperationQueue"]
                struct PresenterQueue;
            );
            impl PresenterQueue {
                extern_methods!(
                    #[unsafe(method(new))]
                    #[unsafe(method_family = new)]
                    fn new() -> Retained<Self>;
                );
            }

            struct PresenterState {
                path: String,
                queue: Retained<PresenterQueue>,
                requested: channel::Sender<()>,
                release: Mutex<channel::Receiver<()>>,
            }

            define_class!(
                // NSObject permits this subclass; every callback's shared
                // channel state is synchronized independently of Foundation.
                #[unsafe(super(NSObject))]
                #[ivars = PresenterState]
                struct PendingReadPresenter;

                unsafe impl NSObjectProtocol for PendingReadPresenter {}

                unsafe impl NSFilePresenter for PendingReadPresenter {
                    #[unsafe(method_id(presentedItemOperationQueue))]
                    fn operation_queue(&self) -> Retained<PresenterQueue> {
                        self.ivars().queue.clone()
                    }
                    #[unsafe(method_id(presentedItemURL))]
                    fn item_url(&self) -> Option<Retained<NSURL>> {
                        Some(NSURL::fileURLWithPath(&NSString::from_str(
                            &self.ivars().path,
                        )))
                    }

                    #[unsafe(method(relinquishPresentedItemToReader:))]
                    unsafe fn relinquish_to_reader(
                        &self,
                        reader: &block2::DynBlock<dyn Fn(*mut block2::DynBlock<dyn Fn()>)>,
                    ) {
                        let _ = self.ivars().requested.send(());
                        // A real Foundation notification proves the read is
                        // pending. Hold the response until the test cleans up.
                        let _ = self.ivars().release.lock().unwrap().recv();
                        reader.call((std::ptr::null_mut(),));
                    }
                }
            );

            impl PendingReadPresenter {
                fn new(state: PresenterState) -> Retained<Self> {
                    let this = Self::alloc().set_ivars(state);
                    // SAFETY: NSObject's initializer has this signature.
                    unsafe { msg_send![super(this), init] }
                }
            }

            struct Gate {
                presenter: Retained<PendingReadPresenter>,
                release: Option<channel::Sender<()>>,
                path: PathBuf,
            }
            impl Drop for Gate {
                fn drop(&mut self) {
                    // Unblock the Foundation callback even if an assertion
                    // fails; never leave a withheld presenter response behind.
                    if let Some(release) = self.release.take() {
                        let _ = release.send(());
                    }
                    NSFileCoordinator::removeFilePresenter(ProtocolObject::from_ref(
                        &*self.presenter,
                    ));
                    let _ = std::fs::remove_file(&self.path);
                }
            }

            #[test]
            fn cancellation_stops_native_coordination_waiting_for_a_presenter() {
                autoreleasepool(|_| {
                    let path = std::env::temp_dir()
                        .join(format!("localsend-coordination-{}", uuid::Uuid::new_v4()));
                    std::fs::write(&path, b"coordinated content").unwrap();
                    let (requested_tx, requested_rx) = channel::channel();
                    let (release_tx, release_rx) = channel::channel();
                    let presenter = PendingReadPresenter::new(PresenterState {
                        path: path.to_str().unwrap().to_owned(),
                        queue: PresenterQueue::new(),
                        requested: requested_tx,
                        release: Mutex::new(release_rx),
                    });
                    NSFileCoordinator::addFilePresenter(ProtocolObject::from_ref(&*presenter));
                    let gate = Gate {
                        presenter,
                        release: Some(release_tx),
                        path: path.clone(),
                    };
                    let cancellation = Arc::new(Cancellation::default());
                    let reader_cancellation = cancellation.clone();
                    let accessor_called = Arc::new(AtomicBool::new(false));
                    let reader_accessor_called = accessor_called.clone();
                    let (finished_tx, finished_rx) = channel::channel();
                    let reader = thread::spawn(move || {
                        autoreleasepool(|_| {
                            let url =
                                NSURL::fileURLWithPath(&NSString::from_str(path.to_str().unwrap()));
                            let result = coordinate(&url, &reader_cancellation, |path| {
                                reader_accessor_called.store(true, Ordering::Release);
                                std::fs::read(path)
                            });
                            let _ = finished_tx.send(result);
                        });
                    });

                    // Unlike a delay or a pre-call registration hook, this
                    // callback comes from the native pending read request.
                    requested_rx
                        .recv_timeout(Duration::from_secs(5))
                        .expect("Foundation did not ask the presenter to relinquish the file");
                    assert!(!accessor_called.load(Ordering::Acquire));
                    assert!(matches!(
                        finished_rx.try_recv(),
                        Err(channel::TryRecvError::Empty)
                    ));
                    assert!(cancellation.coordinator.lock().unwrap().is_some());
                    cancellation.cancel();
                    let result = finished_rx
                        .recv_timeout(Duration::from_secs(5))
                        .expect("native coordination remained pending after cancellation");
                    assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
                    assert!(!accessor_called.load(Ordering::Acquire));
                    assert!(cancellation.coordinator.lock().unwrap().is_none());
                    reader.join().unwrap();
                    // The request has finished while its native presenter
                    // response is still held; only now release that response.
                    drop(gate);
                });
            }
        }

        #[tokio::test]
        async fn dropping_stream_wakes_backpressured_reader() {
            let (sender, receiver) = mpsc::channel(FILE_CHANNEL_CAPACITY);
            let cancellation = Arc::new(Cancellation::default());
            let stream = ScopedStream {
                receiver,
                cancellation: cancellation.clone(),
            };
            let (filled_tx, filled_rx) = tokio::sync::oneshot::channel();
            let worker = tokio::task::spawn_blocking(move || {
                // Match the producer's bounded queue without relying on sleeps.
                for _ in 0..FILE_CHANNEL_CAPACITY {
                    sender.blocking_send(Ok(Bytes::from_static(b"x"))).unwrap();
                }
                filled_tx.send(()).unwrap();
                read_chunks(io::repeat(1), &sender, &cancellation)
            });
            filled_rx.await.unwrap();
            drop(stream);
            let result = tokio::time::timeout(std::time::Duration::from_secs(2), worker)
                .await
                .expect("reader remained blocked after consumer dropped")
                .unwrap();
            assert!(result.is_ok() || result.unwrap_err().kind() == io::ErrorKind::Interrupted);
        }

        #[tokio::test]
        async fn read_failure_after_a_chunk_is_forwarded() {
            struct FailingReader(bool);
            impl Read for FailingReader {
                fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                    if self.0 {
                        return Err(io::Error::new(
                            io::ErrorKind::PermissionDenied,
                            "provider revoked access",
                        ));
                    }
                    self.0 = true;
                    buffer[..3].copy_from_slice(b"abc");
                    Ok(3)
                }
            }
            let (sender, receiver) = mpsc::channel(FILE_CHANNEL_CAPACITY);
            let cancellation = Arc::new(Cancellation::default());
            let mut stream = ScopedStream {
                receiver,
                cancellation: cancellation.clone(),
            };
            tokio::task::spawn_blocking(move || {
                if let Err(error) = read_chunks(FailingReader(false), &sender, &cancellation) {
                    sender.blocking_send(Err(error)).unwrap();
                }
            });
            assert_eq!(&stream.next().await.unwrap().unwrap()[..], b"abc");
            assert_eq!(
                stream.next().await.unwrap().unwrap_err().kind(),
                io::ErrorKind::PermissionDenied
            );
            assert!(stream.next().await.is_none());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_scoped_path_escape() {
        for path in [
            "",
            "/tmp/file",
            "../file",
            "nested/../../file",
            "nested/../file",
        ] {
            assert!(validate_relative_path(Path::new(path)).is_err(), "{path}");
        }
        assert!(validate_relative_path(Path::new("nested/file")).is_ok());
    }
}
