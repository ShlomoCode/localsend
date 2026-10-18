#![doc = include_str!("../README.md")]

//! Stateful LocalSend discovery and transfer sessions for non-UI callers.
//!
//! Call [`Session::next_event`] while a session is active: server decisions,
//! transfer completion, and discovery updates are processed by that event
//! loop. The method is safe to use in `tokio::select!`; it does not await after
//! removing an event from a channel. Call [`Session::shutdown`] to wait for
//! network sockets to close. Dropping a session also closes its stop channels.

mod identity;
mod offer;
mod paired;
mod sanitize;
mod send_task;
mod session;
mod target;
pub mod util;

pub use identity::Identity;
pub use offer::SendPayload;
pub use paired::{PairedChannel, PairedDevices};
pub use session::{
    Device, FileSummary, ReceivePolicy, ReceiveStatus, Session, SessionConfig, SessionEvent,
    SessionStatus, TransferStatus,
};
pub use target::TargetSelector as Target;

// The interactive CLI uses the same upload implementation through a small
// event adapter; these types are transport mechanics, not session state.
pub use send_task::{FileSource, SendCancel, TaskEvent, run_send};
