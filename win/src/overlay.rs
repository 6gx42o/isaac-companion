//! An always-on-top stat readout for Windows, drawn with GDI.
//!
//! The Mac build gets this from AppKit's NSPanel. There is no portable equivalent, so
//! this is raw Win32 through `extern "system"` declarations rather than a crate -- which
//! keeps the promise this binary makes everywhere else: zero dependencies, one file, no
//! runtime to install.
//!
//! **Two things worth knowing before you rely on it.**
//!
//! An overlay cannot draw over *exclusive* fullscreen. That is a property of how the
//! display is being driven, not a bug here and not something any program can work around
//! from outside the game. Isaac must be in windowed or borderless-windowed mode, which
//! the UI says plainly rather than leaving you to discover it.
//!
//! And it has never been watched running over a real game. CI creates the window and
//! checks it exists, which proves the Win32 calls are right; it cannot prove the thing
//! looks correct above Isaac. That needs a person at a Windows machine.

#![cfg(windows)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::run::Data;
use crate::State;

// ---- the slice of Win32 we need ---------------------------------------------
//
// Declared by hand. Each one is here because something below calls it; the alternative
// is a dependency whose only job is to retype these same signatures.

type Handle = *mut core::ffi::c_void;
type Wparam = usize;
type Lparam = isize;
type Lresult = isize;

#[repr(C)]
#[derive(Clone, Copy)]
struct Point {
    x: i32,
    y: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

#[repr(C)]
struct Msg {
    hwnd: Handle,
    message: u32,
    wparam: Wparam,
    lparam: Lparam,
    time: u32,
    pt: Point,
}

#[repr(C)]
struct PaintStruct {
    hdc: Handle,
    erase: i32,
    paint: Rect,
    restore: i32,
    inc_update: i32,
    reserved: [u8; 32],
}

#[repr(C)]
struct WndClassW {
    style: u32,
    wnd_proc: Option<unsafe extern "system" fn(Handle, u32, Wparam, Lparam) -> Lresult>,
    cls_extra: i32,
    wnd_extra: i32,
    instance: Handle,
    icon: Handle,
    cursor: Handle,
    background: Handle,
    menu_name: *const u16,
    class_name: *const u16,
}

#[link(name = "user32")]
extern "system" {
    fn RegisterClassW(class: *const WndClassW) -> u16;
    fn CreateWindowExW(
        ex_style: u32,
        class_name: *const u16,
        window_name: *const u16,
        style: u32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        parent: Handle,
        menu: Handle,
        instance: Handle,
        param: *mut core::ffi::c_void,
    ) -> Handle;
    fn DefWindowProcW(hwnd: Handle, msg: u32, wp: Wparam, lp: Lparam) -> Lresult;
    fn ShowWindow(hwnd: Handle, cmd: i32) -> i32;
    fn UpdateWindow(hwnd: Handle) -> i32;
    fn DestroyWindow(hwnd: Handle) -> i32;
    fn FindWindowW(class_name: *const u16, window_name: *const u16) -> Handle;
    fn SetLayeredWindowAttributes(hwnd: Handle, key: u32, alpha: u8, flags: u32) -> i32;
    fn SetTimer(hwnd: Handle, id: usize, ms: u32, proc_: usize) -> usize;
    fn GetMessageW(msg: *mut Msg, hwnd: Handle, min: u32, max: u32) -> i32;
    fn TranslateMessage(msg: *const Msg) -> i32;
    fn DispatchMessageW(msg: *const Msg) -> Lresult;
    fn PostQuitMessage(code: i32);
    fn BeginPaint(hwnd: Handle, ps: *mut PaintStruct) -> Handle;
    fn EndPaint(hwnd: Handle, ps: *const PaintStruct) -> i32;
    fn InvalidateRect(hwnd: Handle, rect: *const Rect, erase: i32) -> i32;
    fn GetClientRect(hwnd: Handle, rect: *mut Rect) -> i32;
    fn FillRect(hdc: Handle, rect: *const Rect, brush: Handle) -> i32;
    fn DrawTextW(hdc: Handle, text: *const u16, count: i32, rect: *mut Rect, format: u32) -> i32;
    fn GetSystemMetrics(index: i32) -> i32;
}

#[link(name = "gdi32")]
extern "system" {
    fn CreateSolidBrush(colour: u32) -> Handle;
    fn CreateFontW(
        height: i32,
        width: i32,
        escapement: i32,
        orientation: i32,
        weight: i32,
        italic: u32,
        underline: u32,
        strikeout: u32,
        charset: u32,
        out_precision: u32,
        clip_precision: u32,
        quality: u32,
        pitch_and_family: u32,
        face: *const u16,
    ) -> Handle;
    fn SelectObject(hdc: Handle, obj: Handle) -> Handle;
    fn DeleteObject(obj: Handle) -> i32;
    fn SetTextColor(hdc: Handle, colour: u32) -> u32;
    fn SetBkMode(hdc: Handle, mode: i32) -> i32;
}

// Window styles. Together these make a window that floats above everything, never takes
// focus, never appears in the taskbar or Alt-Tab, and passes every click straight
// through to the game underneath.
const WS_EX_LAYERED: u32 = 0x0008_0000;
const WS_EX_TRANSPARENT: u32 = 0x0000_0020;
const WS_EX_TOPMOST: u32 = 0x0000_0008;
const WS_EX_TOOLWINDOW: u32 = 0x0000_0080;
const WS_EX_NOACTIVATE: u32 = 0x0800_0000;
const WS_POPUP: u32 = 0x8000_0000;

const SW_SHOWNOACTIVATE: i32 = 4;
const LWA_ALPHA: u32 = 0x0000_0002;
const WM_PAINT: u32 = 0x000F;
const WM_TIMER: u32 = 0x0113;
const WM_DESTROY: u32 = 0x0002;
const TRANSPARENT_BK: i32 = 1;
const DT_LEFT: u32 = 0x0000;
const DT_NOCLIP: u32 = 0x0100;
const SM_CXSCREEN: i32 = 0;
const DEFAULT_CHARSET: u32 = 1;
const CLEARTYPE_QUALITY: u32 = 5;

const CLASS_NAME: &str = "IsaacCompanionOverlay";
const WINDOW_TITLE: &str = "Isaac Companion Overlay";
const WIDTH: i32 = 260;
const HEIGHT: i32 = 190;

/// Palette, as GDI wants it: 0x00BBGGRR, not RGB.
const BG: u32 = 0x000E_0B15; // --panel
const FG: u32 = 0x00C6_D9E8; // --ash
const DIM: u32 = 0x0075_7F9A; // --dim
const HOT: u32 = 0x002B_54E2; // --hot

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// What the window paints. Refreshed from the shared state on a timer, because the
/// window procedure runs on its own thread and must not block on the tailer's lock.
static LINES: Mutex<Vec<(String, u32)>> = Mutex::new(Vec::new());

unsafe extern "system" fn wnd_proc(hwnd: Handle, msg: u32, wp: Wparam, lp: Lparam) -> Lresult {
    match msg {
        WM_PAINT => {
            let mut ps: PaintStruct = std::mem::zeroed();
            let hdc = BeginPaint(hwnd, &mut ps);

            let mut client = Rect { left: 0, top: 0, right: 0, bottom: 0 };
            GetClientRect(hwnd, &mut client);
            let brush = CreateSolidBrush(BG);
            FillRect(hdc, &client, brush);
            DeleteObject(brush);

            let face = wide("Consolas");
            let font = CreateFontW(
                -15, 0, 0, 0, 400, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0,
                face.as_ptr(),
            );
            let old = SelectObject(hdc, font);
            SetBkMode(hdc, TRANSPARENT_BK);

            let mut y = 10;
            if let Ok(lines) = LINES.lock() {
                for (text, colour) in lines.iter() {
                    SetTextColor(hdc, *colour);
                    let mut at = Rect { left: 12, top: y, right: WIDTH - 8, bottom: y + 22 };
                    let w = wide(text);
                    DrawTextW(hdc, w.as_ptr(), -1, &mut at, DT_LEFT | DT_NOCLIP);
                    y += 21;
                }
            }

            SelectObject(hdc, old);
            DeleteObject(font);
            EndPaint(hwnd, &ps);
            0
        }
        WM_TIMER => {
            InvalidateRect(hwnd, std::ptr::null(), 0);
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// Rebuilds the painted lines from the live run.
///
/// Same character resolution and same stat model the browser readout uses -- both go
/// through `Run::character` and `compute`, so the overlay cannot drift into showing
/// different numbers from the page.
fn refresh(state: &Arc<Mutex<State>>, data: &Arc<Data>, running: &Arc<AtomicBool>) {
    let Ok(s) = state.lock() else { return };
    let character = s.run.character(data);
    let stats = crate::stats::compute(&character, &s.run.deltas(data));

    let mut out: Vec<(String, u32)> = vec![(character.name.clone(), FG)];
    out.push((
        match (&s.run.seed, running.load(Ordering::Relaxed)) {
            (Some(seed), true) => format!("{seed}  ·  floor {}", s.run.stage),
            (Some(seed), false) => format!("{seed}  ·  game closed"),
            (None, _) => "waiting for a run".to_string(),
        },
        DIM,
    ));

    for (label, stat) in [
        ("damage", &stats.damage),
        ("tears", &stats.tears),
        ("delay", &stats.tear_delay),
        ("range", &stats.range),
        ("shotspd", &stats.shot_speed),
        ("speed", &stats.speed),
        ("luck", &stats.luck),
    ] {
        out.push((
            format!(
                "{label:<8}{}{:.2}",
                if stat.approx { "~" } else { " " },
                stat.value
            ),
            if stat.approx { HOT } else { FG },
        ));
    }
    if let Ok(mut lines) = LINES.lock() {
        *lines = out;
    }
}

/// Opens the overlay and runs its message loop. Blocks, so it owns a thread.
pub fn run(state: Arc<Mutex<State>>, data: Arc<Data>, running: Arc<AtomicBool>) {
    unsafe {
        let class = wide(CLASS_NAME);
        let title = wide(WINDOW_TITLE);

        let wc = WndClassW {
            style: 0,
            wnd_proc: Some(wnd_proc),
            cls_extra: 0,
            wnd_extra: 0,
            instance: std::ptr::null_mut(),
            icon: std::ptr::null_mut(),
            cursor: std::ptr::null_mut(),
            background: std::ptr::null_mut(),
            menu_name: std::ptr::null(),
            class_name: class.as_ptr(),
        };
        // A second call fails harmlessly if the class is already registered.
        RegisterClassW(&wc);

        // Top right by default, a little in from the edge: the game's own HUD lives top
        // left, so this is the corner that is not already spoken for.
        let x = GetSystemMetrics(SM_CXSCREEN) - WIDTH - 24;
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
                | WS_EX_NOACTIVATE,
            class.as_ptr(),
            title.as_ptr(),
            WS_POPUP,
            x.max(0),
            24,
            WIDTH,
            HEIGHT,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        if hwnd.is_null() {
            eprintln!("could not create the overlay window; the readout in the browser still works");
            return;
        }

        SetLayeredWindowAttributes(hwnd, 0, 235, LWA_ALPHA);
        // SHOWNOACTIVATE, not SHOW: taking focus would minimise the game.
        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        UpdateWindow(hwnd);
        SetTimer(hwnd, 1, 400, 0);

        {
            let state = Arc::clone(&state);
            let data = Arc::clone(&data);
            let running = Arc::clone(&running);
            std::thread::spawn(move || loop {
                refresh(&state, &data, &running);
                std::thread::sleep(std::time::Duration::from_millis(400));
            });
        }

        let mut msg: Msg = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

/// Creates the window, checks Windows agrees it exists, and tears it down.
///
/// This is what CI can actually assert. It proves the class registration, the extended
/// style combination and the window creation are right -- the parts that either work or
/// fail outright. It says nothing about whether the overlay looks correct above a
/// running game, which no automated check can answer.
pub fn selftest() -> bool {
    unsafe {
        let class = wide(CLASS_NAME);
        let title = wide(WINDOW_TITLE);
        let wc = WndClassW {
            style: 0,
            wnd_proc: Some(wnd_proc),
            cls_extra: 0,
            wnd_extra: 0,
            instance: std::ptr::null_mut(),
            icon: std::ptr::null_mut(),
            cursor: std::ptr::null_mut(),
            background: std::ptr::null_mut(),
            menu_name: std::ptr::null(),
            class_name: class.as_ptr(),
        };
        RegisterClassW(&wc);
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
                | WS_EX_NOACTIVATE,
            class.as_ptr(),
            title.as_ptr(),
            WS_POPUP,
            0,
            0,
            WIDTH,
            HEIGHT,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        );
        if hwnd.is_null() {
            eprintln!("OVERLAY: CreateWindowExW returned null");
            return false;
        }
        SetLayeredWindowAttributes(hwnd, 0, 235, LWA_ALPHA);
        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let found = FindWindowW(class.as_ptr(), title.as_ptr());
        let ok = !found.is_null();
        println!(
            "OVERLAY: created={} found_by_name={}",
            !hwnd.is_null(),
            ok
        );
        DestroyWindow(hwnd);
        ok
    }
}
