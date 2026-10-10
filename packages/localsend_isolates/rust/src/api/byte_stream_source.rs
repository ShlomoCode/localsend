use flutter_rust_bridge::frb;
pub use localsend::model::byte_stream_source::ByteStreamSource;

#[frb(mirror(ByteStreamSource))]
pub enum _ByteStreamSource {
    Path { path: String },
    Bytes { bytes: Vec<u8> },
    FileDescriptor { fd: i32 },
    Generated { descriptor: String },
}
