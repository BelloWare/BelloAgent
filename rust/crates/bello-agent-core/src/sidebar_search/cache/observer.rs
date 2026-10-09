//! Test-only, official-ffi forwarding observer. Registered only in disposable
//! child test processes, never default, never compiled into a production build.
//! This observes SQLite VFS operations, not arbitrary OS/process I/O or erasure.
#![allow(unsafe_op_in_unsafe_fn)]
use rusqlite::ffi::*;
use std::{
    ffi::{CStr, c_char, c_int, c_void},
    sync::{
        Mutex,
        atomic::{AtomicI64, AtomicUsize, Ordering},
    },
};
static OPENS: Mutex<Vec<(i32, bool)>> = Mutex::new(Vec::new());
static DELETES: AtomicUsize = AtomicUsize::new(0);
static SHM: AtomicUsize = AtomicUsize::new(0);
static UNSAFE_SHM: AtomicUsize = AtomicUsize::new(0);
static WRITES: AtomicUsize = AtomicUsize::new(0);
static READS: AtomicUsize = AtomicUsize::new(0);
static FAIL_AFTER: AtomicI64 = AtomicI64::new(-1);
static ROOT: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);
static OUTSIDE: AtomicUsize = AtomicUsize::new(0);
#[repr(C)]
struct File {
    base: sqlite3_file,
    real: *mut sqlite3_file,
    methods: sqlite3_io_methods,
    shm: Option<std::path::PathBuf>,
}
unsafe fn file<'a>(p: *mut sqlite3_file) -> &'a mut File {
    &mut *p.cast()
}
unsafe fn original(p: *mut sqlite3_vfs) -> *mut sqlite3_vfs {
    (*p).pAppData.cast()
}
fn path_checked(name: *const c_char) {
    if name.is_null() {
        return;
    }
    // SAFETY: SQLite callbacks supply a valid NUL-terminated filename.
    let path = std::path::PathBuf::from(unsafe { CStr::from_ptr(name) }.to_string_lossy().as_ref());
    if let Ok(root) = ROOT.lock()
        && let Some(root) = root.as_ref()
        && !path.starts_with(root)
    {
        OUTSIDE.fetch_add(1, Ordering::Relaxed);
    }
}
unsafe extern "C" fn open(
    v: *mut sqlite3_vfs,
    n: sqlite3_filename,
    p: *mut sqlite3_file,
    flags: c_int,
    out: *mut c_int,
) -> c_int {
    if let Ok(mut events) = OPENS.lock() {
        events.push((flags, n.is_null()));
    }
    path_checked(n);
    let real_vfs = original(v);
    let real = libc::calloc(1, (*real_vfs).szOsFile as usize).cast::<sqlite3_file>();
    if real.is_null() {
        return SQLITE_NOMEM;
    }
    let code = ((*real_vfs).xOpen.unwrap())(real_vfs, n, real, flags, out);
    if code != SQLITE_OK {
        if !(*real).pMethods.is_null() {
            ((*(*real).pMethods).xClose.unwrap())(real);
        }
        libc::free(real.cast());
        (*p).pMethods = std::ptr::null();
        return code;
    }
    let mut methods = *(*real).pMethods;
    methods.xClose = Some(close);
    methods.xRead = Some(read);
    methods.xWrite = Some(write);
    methods.xTruncate = Some(truncate);
    methods.xSync = Some(sync);
    methods.xFileSize = Some(size);
    methods.xLock = Some(lock);
    methods.xUnlock = Some(unlock);
    methods.xCheckReservedLock = Some(reserved);
    methods.xFileControl = Some(control);
    methods.xSectorSize = Some(sector);
    methods.xDeviceCharacteristics = Some(characteristics);
    if methods.iVersion >= 2 {
        if methods.xShmMap.is_some() {
            methods.xShmMap = Some(shm_map);
        }
        if methods.xShmLock.is_some() {
            methods.xShmLock = Some(shm_lock);
        }
        if methods.xShmBarrier.is_some() {
            methods.xShmBarrier = Some(shm_barrier);
        }
        if methods.xShmUnmap.is_some() {
            methods.xShmUnmap = Some(shm_unmap);
        }
    }
    if methods.iVersion >= 3 {
        if methods.xFetch.is_some() {
            methods.xFetch = Some(fetch);
        }
        if methods.xUnfetch.is_some() {
            methods.xUnfetch = Some(unfetch);
        }
    }
    p.cast::<File>().write(File {
        base: sqlite3_file {
            pMethods: std::ptr::null(),
        },
        real,
        methods,
        shm: if flags & SQLITE_OPEN_MAIN_DB != 0 && !n.is_null() {
            Some(std::path::PathBuf::from(format!(
                "{}-shm",
                CStr::from_ptr(n).to_string_lossy()
            )))
        } else {
            None
        },
    });
    (*p).pMethods = &file(p).methods;
    code
}
unsafe extern "C" fn close(p: *mut sqlite3_file) -> c_int {
    let f = file(p);
    let code = ((*(*f.real).pMethods).xClose.unwrap())(f.real);
    libc::free(f.real.cast());
    f.base.pMethods = std::ptr::null();
    std::ptr::drop_in_place(p.cast::<File>());
    code
}
macro_rules! io_forward {($name:ident,$field:ident,($($arg:ident:$ty:ty),*)->$ret:ty)=>{unsafe extern "C" fn $name(p:*mut sqlite3_file,$($arg:$ty),*)->$ret {let r=file(p).real;((*(*r).pMethods).$field.unwrap())(r,$($arg),*)}};}
unsafe extern "C" fn read(
    p: *mut sqlite3_file,
    buffer: *mut c_void,
    amount: c_int,
    offset: sqlite3_int64,
) -> c_int {
    READS.fetch_add(1, Ordering::Relaxed);
    let r = file(p).real;
    ((*(*r).pMethods).xRead.unwrap())(r, buffer, amount, offset)
}
io_forward!(truncate,xTruncate,(size:sqlite3_int64)->c_int);
io_forward!(sync,xSync,(flags:c_int)->c_int);
io_forward!(size,xFileSize,(size:*mut sqlite3_int64)->c_int);
io_forward!(lock,xLock,(level:c_int)->c_int);
io_forward!(unlock,xUnlock,(level:c_int)->c_int);
io_forward!(reserved,xCheckReservedLock,(out:*mut c_int)->c_int);
io_forward!(control,xFileControl,(op:c_int,arg:*mut c_void)->c_int);
io_forward!(sector,xSectorSize,()->c_int);
io_forward!(characteristics,xDeviceCharacteristics,()->c_int);
io_forward!(shm_lock,xShmLock,(offset:c_int,n:c_int,flags:c_int)->c_int);
io_forward!(shm_barrier,xShmBarrier,()->());
io_forward!(shm_unmap,xShmUnmap,(delete:c_int)->c_int);
io_forward!(fetch,xFetch,(offset:sqlite3_int64,amount:c_int,out:*mut *mut c_void)->c_int);
io_forward!(unfetch,xUnfetch,(offset:sqlite3_int64,pointer:*mut c_void)->c_int);
unsafe extern "C" fn write(
    p: *mut sqlite3_file,
    buffer: *const c_void,
    amount: c_int,
    offset: sqlite3_int64,
) -> c_int {
    WRITES.fetch_add(1, Ordering::Relaxed);
    let count = FAIL_AFTER.load(Ordering::Relaxed);
    if count == 0 {
        return SQLITE_FULL;
    }
    if count > 0 {
        FAIL_AFTER.fetch_sub(1, Ordering::Relaxed);
    }
    let r = file(p).real;
    ((*(*r).pMethods).xWrite.unwrap())(r, buffer, amount, offset)
}
unsafe extern "C" fn shm_map(
    p: *mut sqlite3_file,
    page: c_int,
    size: c_int,
    extend: c_int,
    out: *mut *mut c_void,
) -> c_int {
    SHM.fetch_add(1, Ordering::Relaxed);
    let r = file(p).real;
    let code = ((*(*r).pMethods).xShmMap.unwrap())(r, page, size, extend, out);
    if code == SQLITE_OK {
        use std::os::unix::fs::MetadataExt;
        let safe = file(p)
            .shm
            .as_ref()
            .and_then(|path| std::fs::symlink_metadata(path).ok())
            .is_some_and(|m| {
                m.is_file()
                    && m.mode() & 0o7777 == 0o600
                    && m.nlink() == 1
                    && m.uid() == libc::geteuid()
            });
        if !safe {
            UNSAFE_SHM.fetch_add(1, Ordering::Relaxed);
        }
    }
    code
}
macro_rules! vfs_forward {($name:ident,$field:ident,($($arg:ident:$ty:ty),*)->$ret:ty)=>{unsafe extern "C" fn $name(v:*mut sqlite3_vfs,$($arg:$ty),*)->$ret {let v=original(v);((*v).$field.unwrap())(v,$($arg),*)}};}
unsafe extern "C" fn delete(v: *mut sqlite3_vfs, name: *const c_char, sync: c_int) -> c_int {
    DELETES.fetch_add(1, Ordering::Relaxed);
    path_checked(name);
    let v = original(v);
    ((*v).xDelete.unwrap())(v, name, sync)
}
vfs_forward!(access,xAccess,(name:*const c_char,flags:c_int,out:*mut c_int)->c_int);
vfs_forward!(full,xFullPathname,(name:*const c_char,n:c_int,out:*mut c_char)->c_int);
vfs_forward!(dl_open,xDlOpen,(name:*const c_char)->*mut c_void);
vfs_forward!(dl_error,xDlError,(n:c_int,out:*mut c_char)->());
vfs_forward!(dl_close,xDlClose,(handle:*mut c_void)->());
vfs_forward!(random,xRandomness,(n:c_int,out:*mut c_char)->c_int);
vfs_forward!(sleep,xSleep,(duration:c_int)->c_int);
vfs_forward!(time,xCurrentTime,(out:*mut f64)->c_int);
vfs_forward!(error,xGetLastError,(n:c_int,out:*mut c_char)->c_int);
vfs_forward!(time64,xCurrentTimeInt64,(out:*mut sqlite3_int64)->c_int);
vfs_forward!(set_system,xSetSystemCall,(name:*const c_char,value:sqlite3_syscall_ptr)->c_int);
vfs_forward!(get_system,xGetSystemCall,(name:*const c_char)->sqlite3_syscall_ptr);
vfs_forward!(next_system,xNextSystemCall,(name:*const c_char)->*const c_char);
type Symbol = Option<unsafe extern "C" fn(*mut sqlite3_vfs, *mut c_void, *const c_char)>;
vfs_forward!(dl_sym,xDlSym,(handle:*mut c_void,name:*const c_char)->Symbol);

pub(super) struct Observer {
    // Process-lifetime allocation: even a future test dropping this guard before
    // its connection cannot leave SQLite with a dangling VFS pointer. Tests run
    // in disposable subprocesses, so this deliberately leaked small registry
    // object is reclaimed at process exit, not production lifetime management.
    vfs: *mut sqlite3_vfs,
}
impl Observer {
    pub fn register(root: &std::path::Path) -> Self {
        *ROOT.lock().unwrap() = Some(root.canonicalize().unwrap());
        // SAFETY: registration is isolated in a child process. The allocation
        // stays alive through process exit, including after early unregister;
        // existing SQLite connections therefore never retain a dangling VFS.
        unsafe {
            let original = sqlite3_vfs_find(std::ptr::null());
            assert!(!original.is_null());
            let mut vfs = Box::new(*original);
            vfs.zName = c"bello-private-observer".as_ptr();
            vfs.pNext = std::ptr::null_mut();
            vfs.pAppData = original.cast();
            vfs.szOsFile = std::mem::size_of::<File>() as c_int;
            vfs.xOpen = Some(open);
            vfs.xDelete = Some(delete);
            vfs.xAccess = Some(access);
            vfs.xFullPathname = Some(full);
            vfs.xDlOpen = Some(dl_open);
            vfs.xDlError = Some(dl_error);
            vfs.xDlSym = Some(dl_sym);
            vfs.xDlClose = Some(dl_close);
            vfs.xRandomness = Some(random);
            vfs.xSleep = Some(sleep);
            vfs.xCurrentTime = Some(time);
            vfs.xGetLastError = Some(error);
            if vfs.iVersion >= 2 && vfs.xCurrentTimeInt64.is_some() {
                vfs.xCurrentTimeInt64 = Some(time64);
            }
            if vfs.iVersion >= 3 {
                if vfs.xSetSystemCall.is_some() {
                    vfs.xSetSystemCall = Some(set_system);
                }
                if vfs.xGetSystemCall.is_some() {
                    vfs.xGetSystemCall = Some(get_system);
                }
                if vfs.xNextSystemCall.is_some() {
                    vfs.xNextSystemCall = Some(next_system);
                }
            }
            assert_eq!(sqlite3_vfs_register(&mut *vfs, 0), SQLITE_OK);
            Self {
                vfs: Box::into_raw(vfs),
            }
        }
    }
    pub fn name(&self) -> &str {
        "bello-private-observer"
    }
    pub fn faults_after(&self, n: i64) {
        FAIL_AFTER.store(n, Ordering::Relaxed);
    }
    pub fn counts(&self) -> (usize, usize, usize, usize) {
        (
            OPENS.lock().unwrap().len(),
            SHM.load(Ordering::Relaxed),
            WRITES.load(Ordering::Relaxed),
            DELETES.load(Ordering::Relaxed),
        )
    }
    pub fn reads(&self) -> usize {
        READS.load(Ordering::Relaxed)
    }
    pub fn spill_count(&self) -> usize {
        let bad = SQLITE_OPEN_TEMP_DB
            | SQLITE_OPEN_TEMP_JOURNAL
            | SQLITE_OPEN_TRANSIENT_DB
            | SQLITE_OPEN_SUBJOURNAL
            | SQLITE_OPEN_DELETEONCLOSE;
        OPENS
            .lock()
            .unwrap()
            .iter()
            .filter(|(flags, null)| *null || flags & bad != 0)
            .count()
    }
    pub fn assert_private_no_spill(&self) {
        assert_eq!(OUTSIDE.load(Ordering::Relaxed), 0);
        assert_eq!(UNSAFE_SHM.load(Ordering::Relaxed), 0);
        assert_eq!(self.spill_count(), 0);
    }
    pub fn live_temp_control(&mut self) {
        // Deliberately requests a synthetic platform temp file through the very
        // same adapter. It is a control, excluded from product no-spill counts.
        unsafe {
            let p = libc::calloc(1, std::mem::size_of::<File>()).cast::<sqlite3_file>();
            assert!(!p.is_null());
            let n = OPENS.lock().unwrap().len();
            assert_eq!(
                ((*self.vfs).xOpen.unwrap())(
                    self.vfs,
                    std::ptr::null(),
                    p,
                    SQLITE_OPEN_READWRITE
                        | SQLITE_OPEN_CREATE
                        | SQLITE_OPEN_DELETEONCLOSE
                        | SQLITE_OPEN_TEMP_DB,
                    std::ptr::null_mut()
                ),
                SQLITE_OK
            );
            assert_eq!(OPENS.lock().unwrap().len(), n + 1);
            assert!(OPENS.lock().unwrap().last().unwrap().1);
            ((*(*p).pMethods).xClose.unwrap())(p);
            libc::free(p.cast());
            OPENS.lock().unwrap().pop();
        }
    }
}
impl Drop for Observer {
    fn drop(&mut self) {
        unsafe {
            sqlite3_vfs_unregister(self.vfs);
        }
    }
}
