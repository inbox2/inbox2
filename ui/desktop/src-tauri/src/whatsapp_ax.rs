//! Driving WhatsApp Desktop's own window through the macOS Accessibility API
//! (macOS only). WhatsApp has no API on the Mac, but its window carries stable
//! accessibility identifiers (the ones Meta's UI tests use: `ChatBar_ComposerTextView`,
//! `ChatBar_SendButton`, `WAMultiSendBottomBarView_SendButton`, …), so Inbox2 can type,
//! paste and press Send in it — without bringing WhatsApp to the front.
//!
//! Needs Inbox2 to be trusted under System Settings › Privacy & Security ›
//! Accessibility. Only a WhatsApp send asks for that, and this module
//! only ever attaches to WhatsApp's own process (`BUNDLE_ID`).
//!
//! Keys are posted to WhatsApp's process alone (`CGEventPostToPid`), never to the
//! system, so whatever the person is typing elsewhere is untouched.

use core_foundation::array::CFArray;
use core_foundation::base::{CFType, CFTypeRef, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::event::{CGEvent, CGEventFlags, CGKeyCode};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use objc::runtime::Object;
use objc::{class, msg_send, sel, sel_impl};
use std::ffi::{c_void, CStr, CString};
use std::time::{Duration, Instant};

pub const BUNDLE_ID: &str = "net.whatsapp.WhatsApp";

type AXUIElementRef = *const c_void;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> bool;
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(e: AXUIElementRef, attr: CFStringRef, value: *mut CFTypeRef) -> i32;
    fn AXUIElementSetAttributeValue(e: AXUIElementRef, attr: CFStringRef, value: CFTypeRef) -> i32;
    fn AXUIElementPerformAction(e: AXUIElementRef, action: CFStringRef) -> i32;
    fn AXUIElementSetMessagingTimeout(e: AXUIElementRef, seconds: f32) -> i32;
    static kAXTrustedCheckOptionPrompt: CFStringRef;
}

// NSRunningApplication / NSPasteboard (already loaded in the app; named for clarity).
#[link(name = "AppKit", kind = "framework")]
extern "C" {}

/// Is Inbox2 allowed to use Accessibility? `prompt` adds it to the list in
/// System Settings and shows macOS's own "allow" dialog when it isn't yet.
pub fn trusted(prompt: bool) -> bool {
    unsafe {
        let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
        let opts = CFDictionary::from_CFType_pairs(&[(key, CFBoolean::from(prompt))]);
        AXIsProcessTrustedWithOptions(opts.as_CFTypeRef())
    }
}

/// WhatsApp's pid when it is running.
pub fn pid() -> Option<i32> {
    unsafe {
        let id = nsstring(BUNDLE_ID);
        let apps: *mut Object = msg_send![class!(NSRunningApplication), runningApplicationsWithBundleIdentifier: id];
        let first: *mut Object = msg_send![apps, firstObject];
        if first.is_null() {
            return None;
        }
        let pid: i32 = msg_send![first, processIdentifier];
        Some(pid)
    }
}

/// Bring Inbox2 itself back to the front (after WhatsApp had to be shown).
pub fn activate_self() {
    unsafe {
        let me: *mut Object = msg_send![class!(NSRunningApplication), currentApplication];
        // NSApplicationActivateIgnoringOtherApps
        let _: bool = msg_send![me, activateWithOptions: 2usize];
    }
}

/// One accessibility element (retained; released on drop through CFType).
pub struct Ax(CFType);

impl Ax {
    pub fn app(pid: i32) -> Ax {
        let el = Ax(unsafe { CFType::wrap_under_create_rule(AXUIElementCreateApplication(pid)) });
        // A busy WhatsApp must not hang the caller for the default 6 s per call.
        unsafe { AXUIElementSetMessagingTimeout(el.raw(), 2.0) };
        el
    }

    fn raw(&self) -> AXUIElementRef {
        self.0.as_CFTypeRef()
    }

    fn attr(&self, name: &str) -> Option<CFType> {
        let mut out: CFTypeRef = std::ptr::null();
        let err = unsafe { AXUIElementCopyAttributeValue(self.raw(), CFString::new(name).as_concrete_TypeRef(), &mut out) };
        (err == 0 && !out.is_null()).then(|| unsafe { CFType::wrap_under_create_rule(out) })
    }

    fn string(&self, name: &str) -> Option<String> {
        self.attr(name)?.downcast::<CFString>().map(|s| s.to_string())
    }

    pub fn description(&self) -> Option<String> {
        self.string("AXDescription")
    }

    /// The text in a text field: `Ok("")` when it's empty (AX reports "no
    /// value"), an error when it can't be read at all.
    pub fn text(&self) -> Result<String, String> {
        let mut out: CFTypeRef = std::ptr::null();
        let err = unsafe { AXUIElementCopyAttributeValue(self.raw(), CFString::new("AXValue").as_concrete_TypeRef(), &mut out) };
        const NO_VALUE: i32 = -25212; // kAXErrorNoValue
        match err {
            NO_VALUE => Ok(String::new()),
            0 if out.is_null() => Ok(String::new()),
            0 => {
                let v = unsafe { CFType::wrap_under_create_rule(out) };
                v.downcast::<CFString>().map(|s| s.to_string()).ok_or_else(|| "WhatsApp's message box holds no text".into())
            }
            e => Err(format!("Couldn't read WhatsApp's message box ({e})")),
        }
    }

    pub fn identifier(&self) -> Option<String> {
        self.string("AXIdentifier")
    }

    fn elements(&self, name: &str) -> Vec<Ax> {
        let Some(v) = self.attr(name) else { return vec![] };
        let Some(arr) = v.downcast::<CFArray>() else { return vec![] };
        arr.iter()
            .map(|p| Ax(unsafe { CFType::wrap_under_get_rule(*p as CFTypeRef) }))
            .collect()
    }

    pub fn children(&self) -> Vec<Ax> {
        self.elements("AXChildren")
    }

    pub fn windows(&self) -> Vec<Ax> {
        self.elements("AXWindows")
    }

    /// Depth-first search for an identifier.
    pub fn find(&self, id: &str) -> Option<Ax> {
        self.find_in(id, 0)
    }

    fn find_in(&self, id: &str, depth: usize) -> Option<Ax> {
        if depth > 40 {
            return None;
        }
        if self.identifier().as_deref() == Some(id) {
            return Some(Ax(self.0.clone()));
        }
        self.children().into_iter().find_map(|c| c.find_in(id, depth + 1))
    }

    /// How many elements carry this identifier.
    pub fn count(&self, id: &str) -> usize {
        fn walk(el: &Ax, id: &str, depth: usize, n: &mut usize) {
            if depth > 40 {
                return;
            }
            if el.identifier().as_deref() == Some(id) {
                *n += 1;
                return;
            }
            for c in el.children() {
                walk(&c, id, depth + 1, n);
            }
        }
        let mut n = 0;
        walk(self, id, 0, &mut n);
        n
    }

    fn set(&self, name: &str, value: &CFType) -> Result<(), String> {
        match unsafe { AXUIElementSetAttributeValue(self.raw(), CFString::new(name).as_concrete_TypeRef(), value.as_CFTypeRef()) } {
            0 => Ok(()),
            e => Err(format!("WhatsApp refused setting {name} ({e})")),
        }
    }

    pub fn set_value(&self, text: &str) -> Result<(), String> {
        self.set("AXValue", &CFString::new(text).as_CFType())
    }

    pub fn focus(&self) -> Result<(), String> {
        self.set("AXFocused", &CFBoolean::true_value().as_CFType())
    }

    pub fn press(&self) -> Result<(), String> {
        self.perform("AXPress")
    }

    pub fn perform(&self, action: &str) -> Result<(), String> {
        match unsafe { AXUIElementPerformAction(self.raw(), CFString::new(action).as_concrete_TypeRef()) } {
            0 => Ok(()),
            e => Err(format!("WhatsApp refused {action} ({e})")),
        }
    }
}

/// Poll `f` until it yields something or `within` passes.
pub fn wait_for<T>(within: Duration, mut f: impl FnMut() -> Option<T>) -> Option<T> {
    let end = Instant::now() + within;
    loop {
        if let Some(v) = f() {
            return Some(v);
        }
        if Instant::now() >= end {
            return None;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

// ── Keys, posted to WhatsApp's process only ─────────────────────────────────

pub const KEY_SPACE: CGKeyCode = 49;
pub const KEY_DELETE: CGKeyCode = 51;
pub const KEY_V: CGKeyCode = 9;
const KEY_COMMAND: CGKeyCode = 55;

fn post(pid: i32, code: CGKeyCode, down: bool, flags: CGEventFlags) -> Result<(), String> {
    let src = CGEventSource::new(CGEventSourceStateID::Private).map_err(|_| "no event source")?;
    let e = CGEvent::new_keyboard_event(src, code, down).map_err(|_| "no key event")?;
    e.set_flags(flags);
    e.post_to_pid(pid);
    std::thread::sleep(Duration::from_millis(20));
    Ok(())
}

/// One key press and release.
pub fn tap(pid: i32, code: CGKeyCode) -> Result<(), String> {
    post(pid, code, true, CGEventFlags::CGEventFlagNull)?;
    post(pid, code, false, CGEventFlags::CGEventFlagNull)
}

/// ⌘V the way a keyboard sends it: Command down, V down, V up, Command up.
pub fn paste(pid: i32) -> Result<(), String> {
    let cmd = CGEventFlags::CGEventFlagCommand;
    post(pid, KEY_COMMAND, true, cmd)?;
    post(pid, KEY_V, true, cmd)?;
    post(pid, KEY_V, false, cmd)?;
    post(pid, KEY_COMMAND, false, CGEventFlags::CGEventFlagNull)
}

// ── The general pasteboard: saved and put back around a paste ───────────────

fn nsstring(s: &str) -> *mut Object {
    let c = CString::new(s).unwrap_or_default();
    unsafe { msg_send![class!(NSString), stringWithUTF8String: c.as_ptr()] }
}

fn rust_string(ns: *mut Object) -> String {
    if ns.is_null() {
        return String::new();
    }
    unsafe {
        let p: *const std::os::raw::c_char = msg_send![ns, UTF8String];
        if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
    }
}

fn general() -> *mut Object {
    unsafe { msg_send![class!(NSPasteboard), generalPasteboard] }
}

/// What the person had copied: every item, every type, as bytes.
pub struct SavedClipboard(Vec<Vec<(String, Vec<u8>)>>);

pub fn save_clipboard() -> SavedClipboard {
    let mut items = Vec::new();
    unsafe {
        let list: *mut Object = msg_send![general(), pasteboardItems];
        let n: usize = if list.is_null() { 0 } else { msg_send![list, count] };
        for i in 0..n {
            let item: *mut Object = msg_send![list, objectAtIndex: i];
            let types: *mut Object = msg_send![item, types];
            let tn: usize = msg_send![types, count];
            let mut parts = Vec::new();
            for t in 0..tn {
                let ty: *mut Object = msg_send![types, objectAtIndex: t];
                let data: *mut Object = msg_send![item, dataForType: ty];
                if data.is_null() {
                    continue;
                }
                let len: usize = msg_send![data, length];
                let bytes: *const u8 = msg_send![data, bytes];
                let v = if len == 0 || bytes.is_null() { Vec::new() } else { std::slice::from_raw_parts(bytes, len).to_vec() };
                parts.push((rust_string(ty), v));
            }
            items.push(parts);
        }
    }
    SavedClipboard(items)
}

pub fn restore_clipboard(saved: SavedClipboard) {
    unsafe {
        let pb = general();
        let _: isize = msg_send![pb, clearContents];
        if saved.0.is_empty() {
            return;
        }
        let arr: *mut Object = msg_send![class!(NSMutableArray), array];
        for parts in saved.0 {
            let item: *mut Object = msg_send![class!(NSPasteboardItem), new];
            for (ty, bytes) in parts {
                let data: *mut Object = msg_send![class!(NSData), dataWithBytes: bytes.as_ptr() length: bytes.len()];
                let _: bool = msg_send![item, setData: data forType: nsstring(&ty)];
            }
            let _: () = msg_send![arr, addObject: item];
            let _: () = msg_send![item, release];
        }
        let _: bool = msg_send![pb, writeObjects: arr];
    }
}

/// The pasteboard's change counter: it moves whenever anything is copied.
pub fn clipboard_changes() -> isize {
    unsafe { msg_send![general(), changeCount] }
}

/// Put one file on the pasteboard, as Finder's ⌘C would.
pub fn copy_file(path: &str) {
    unsafe {
        let pb = general();
        let _: isize = msg_send![pb, clearContents];
        let url: *mut Object = msg_send![class!(NSURL), fileURLWithPath: nsstring(path)];
        let arr: *mut Object = msg_send![class!(NSArray), arrayWithObject: url];
        let _: bool = msg_send![pb, writeObjects: arr];
    }
}
