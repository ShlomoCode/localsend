use flutter_rust_bridge::frb;
pub use localsend::model::content_source::ContentSource;

#[frb(mirror(ContentSource))]
pub enum _ContentSource {
    Path { path: String },
    Bytes { bytes: Vec<u8> },
    FileDescriptor { fd: i32 },
    Generated { descriptor: String },
}
