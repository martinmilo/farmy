//! Kernel-owned process locks. A killed controller releases ownership automatically.
use crate::R;
use std::{
    fs::{File, OpenOptions, TryLockError},
    os::{fd::AsFd, unix::fs::MetadataExt},
    path::Path,
    process::Stdio,
};
/// An exclusive whole-file lock (flock(2) on Unix, through std), held until it is dropped.
pub(crate) struct Lock(Option<File>);
impl Lock {
    pub(crate) fn take(path: &Path) -> R<Self> {
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        file.lock()?;
        Ok(Self(Some(file)))
    }
    /// The lock when no one holds it; `None` while another open file holds it.
    pub(crate) fn try_take(path: &Path) -> R<Option<Self>> {
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Self(Some(file)))),
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Error(e)) => Err(e.into()),
        }
    }
    /// Whether a process holds the lock at `path` right now (this one included, through
    /// another `Lock`). No file: no one ever took it. A lock that cannot be tried counts
    /// as held, so that nothing is cleaned up on a guess.
    pub(crate) fn held(path: &Path) -> bool {
        match File::open(path) {
            Ok(file) => !matches!(file.try_lock(), Ok(())),
            Err(e) => e.kind() != std::io::ErrorKind::NotFound,
        }
    }
    /// Hands the held lock to a child process as its stdin, so that it stays held from
    /// before the spawn until the child ends; the child takes it with `inherit_or_take`.
    pub(crate) fn into_stdio(mut self) -> Stdio {
        self.0.take().map_or_else(Stdio::null, Stdio::from)
    }
    /// The lock a parent handed over as stdin (`into_stdio`) when stdin is the file at
    /// `path`, otherwise taken as `take` does. Stdin then reads /dev/null, so that the
    /// processes started from here do not hold the lock.
    pub(crate) fn inherit_or_take(path: &Path) -> R<Self> {
        let inherited = std::io::stdin()
            .as_fd()
            .try_clone_to_owned()
            .map(File::from);
        if let (Ok(file), Ok(want)) = (inherited, std::fs::metadata(path)) {
            let same = file
                .metadata()
                .map(|m| m.dev() == want.dev() && m.ino() == want.ino())
                .unwrap_or(false);
            if same {
                file.lock()?;
                rustix::stdio::dup2_stdin(File::open("/dev/null")?)
                    .map_err(std::io::Error::from)?;
                return Ok(Self(Some(file)));
            }
        }
        Self::take(path)
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        if let Some(file) = &self.0 {
            #[expect(
                clippy::let_underscore_must_use,
                reason = "closing the file right after releases the lock anyway"
            )]
            let _ = file.unlock();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lock_reads_held_while_taken_and_free_once_dropped() {
        let dir = std::env::temp_dir().join(format!("farmy-lock-{}", std::process::id()));
        let path = dir.join("controller.lock");
        assert!(!Lock::held(&path), "no file: no one ever took it");
        let lock = Lock::take(&path).unwrap();
        assert!(Lock::held(&path));
        assert!(Lock::try_take(&path).unwrap().is_none());
        drop(lock);
        assert!(!Lock::held(&path));
        let again = Lock::try_take(&path).unwrap();
        assert!(again.is_some() && Lock::held(&path));
        drop(again);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
