//! The File Provider extension's entry point (UniFFI, `mobile-ffi`). Every
//! method blocks: the Swift side calls it from its own background queue.

use std::path::Path;
use std::sync::Arc;

use super::engine::{DiskEngine, Progress};
use super::model::*;

#[uniffi::export(callback_interface)]
pub trait DiskTransferListener: Send + Sync {
    fn progress(&self, done: u64, total: u64);
    fn is_cancelled(&self) -> bool;
}

struct Bridge(Box<dyn DiskTransferListener>);
impl Progress for Bridge {
    fn progress(&self, done: u64, total: u64) {
        self.0.progress(done, total)
    }
    fn is_cancelled(&self) -> bool {
        self.0.is_cancelled()
    }
}

#[derive(uniffi::Object)]
pub struct DiskSession {
    engine: DiskEngine,
}

#[uniffi::export]
impl DiskSession {
    /// Opens the engine over the App Group container. `SignedOut` until the
    /// desktop app has written `config.json`.
    #[uniffi::constructor]
    pub fn open(group_dir: String) -> DiskResult<Arc<Self>> {
        Ok(Arc::new(Self { engine: DiskEngine::open(Path::new(&group_dir))? }))
    }

    pub fn item(&self, id: String) -> DiskResult<DiskItem> {
        self.engine.item(&id)
    }

    pub fn children(&self, parent_id: String) -> DiskResult<Vec<DiskItem>> {
        self.engine.children(&parent_id)
    }

    pub fn anchor(&self) -> DiskResult<u64> {
        self.engine.anchor()
    }

    pub fn changes_since(&self, anchor: u64) -> DiskResult<DiskChanges> {
        self.engine.changes_since(anchor)
    }

    /// Pulls server changes; true when Finder should re-read.
    pub fn sync(&self) -> DiskResult<bool> {
        self.engine.sync()
    }

    /// Downloads the current content and returns the file's path.
    pub fn fetch(&self, id: String, listener: Box<dyn DiskTransferListener>) -> DiskResult<String> {
        Ok(self.engine.fetch(&id, &Bridge(listener))?.to_string_lossy().into_owned())
    }

    /// `op_id`: the identifier macOS gave the item being created (stable across retries).
    pub fn create_folder(&self, parent_id: String, name: String, op_id: String) -> DiskResult<DiskItem> {
        self.engine.create_folder(&parent_id, &name, &op_id)
    }

    pub fn create_file(&self, parent_id: String, name: String, src: String, op_id: String, listener: Box<dyn DiskTransferListener>) -> DiskResult<DiskItem> {
        self.engine.create_file(&parent_id, &name, Path::new(&src), &op_id, &Bridge(listener))
    }

    pub fn modify_contents(&self, id: String, base_version: String, src: String, listener: Box<dyn DiskTransferListener>) -> DiskResult<DiskWrite> {
        self.engine.modify_contents(&id, &base_version, Path::new(&src), &Bridge(listener))
    }

    pub fn rename(&self, id: String, name: String) -> DiskResult<DiskItem> {
        self.engine.rename(&id, &name)
    }

    pub fn move_to(&self, id: String, parent_id: String) -> DiskResult<DiskItem> {
        self.engine.move_to(&id, &parent_id)
    }

    pub fn delete(&self, id: String) -> DiskResult<()> {
        self.engine.delete(&id)
    }

    /// The server's thumbnail bytes, or none (folder, sealed, no thumbnail).
    pub fn thumbnail(&self, id: String) -> DiskResult<Option<Vec<u8>>> {
        self.engine.thumbnail(&id)
    }

    /// The item's inbox2 web link.
    pub fn link(&self, id: String) -> DiskResult<String> {
        self.engine.link(&id)
    }

    pub fn status(&self) -> DiskStatus {
        self.engine.status()
    }

    pub fn sealed_file_ids(&self) -> DiskResult<Vec<String>> {
        self.engine.sealed_file_ids()
    }
}
