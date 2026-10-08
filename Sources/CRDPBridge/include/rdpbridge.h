// CRDPBridge — a thin, clean C API over libfreerdp-client3.
// Swift imports ONLY this header; FreeRDP's headers stay internal to rdpbridge.c.
// This keeps the Swift side free of FreeRDP's macros/typedefs and avoids
// having to modularize the entire FreeRDP header tree.
#ifndef RDPBRIDGE_H
#define RDPBRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDPBridge RDPBridge;

// Connection lifecycle states reported to the engine. Mirrors PRD §8.7 honest states.
typedef enum {
    RDPB_STATE_IDLE          = 0,
    RDPB_STATE_CONNECTING    = 1, // TCP + negotiation starting
    RDPB_STATE_AUTHENTICATING= 2, // NLA/CredSSP exchanging credentials
    RDPB_STATE_NEGOTIATING   = 3, // capabilities / channels
    RDPB_STATE_CONNECTED     = 4, // active session, frames flowing
    RDPB_STATE_RECONNECTING  = 5,
    RDPB_STATE_DISCONNECTED  = 6, // clean disconnect
    RDPB_STATE_FAILED        = 7  // error; see code/string
} RDPBridgeState;

// Security negotiation preference.
typedef enum {
    RDPB_SEC_NLA   = 0, // preferred (TLS+CredSSP)
    RDPB_SEC_TLS   = 1,
    RDPB_SEC_RDP   = 2  // legacy, opt-in only
} RDPBridgeSecurity;

// One monitor in a multi-monitor layout. Coordinates are in the remote virtual
// desktop's pixel space, top-left origin (the engine converts from macOS screen
// geometry). Exactly one monitor must have isPrimary = 1.
typedef struct {
    int32_t  x;            // left, in virtual-desktop pixels
    int32_t  y;            // top, in virtual-desktop pixels
    int32_t  width;        // pixels
    int32_t  height;       // pixels
    int      isPrimary;    // 1 for the primary monitor, else 0
    uint32_t scaleFactor;  // DesktopScaleFactor 100..500 (0 => 100)
} RDPBridgeMonitor;

// Immutable connection config. Strings/arrays are borrowed for the duration of the
// rdpbridge_connect() call only (the bridge copies what it needs).
typedef struct {
    const char*       hostname;
    uint32_t          port;             // default 3389
    const char*       username;
    const char*       domain;           // may be NULL/empty
    uint32_t          width;            // desktop width (px, post-scale); union box if multimon
    uint32_t          height;           // desktop height (px); union box if multimon
    uint32_t          desktopScaleFactor; // 100/140/180 for HiDPI; 0 => 100
    RDPBridgeSecurity security;
    int               clipboardEnabled; // 1/0
    int               imageClipboardEnabled; // 1/0: also sync bitmaps (CF_DIB). Requires clipboardEnabled.
    // F-8: offer local FILES to the remote clipboard (Mac→Windows only; the remote
    // pulls contents on demand while the offer stands). Requires clipboardEnabled.
    int               fileClipboardEnabled;  // 1/0
    int               audioEnabled;     // 1/0 (playback)
    // RD Gateway (optional)
    int               gatewayEnabled;   // 1/0
    const char*       gatewayHostname;  // may be NULL
    uint32_t          gatewayPort;
    const char*       gatewayUsername;  // may be NULL (defaults to username)
    const char*       gatewayDomain;
    // F-6: separate gateway password. May be NULL => the gateway authenticates with
    // the MAIN password (pre-F-6 behavior). Borrowed for the duration of
    // rdpbridge_connect() only; the bridge's copy gets the same dup+zero (SEC-2)
    // lifecycle as the main password.
    const char*       gatewayPassword;
    uint32_t          tcpConnectTimeoutMs; // 0 => library default
    // Multi-monitor (optional). When monitorCount > 1, the session spans these
    // monitors; the server delivers one framebuffer covering their bounding box.
    const RDPBridgeMonitor* monitors;   // may be NULL; borrowed (copied by the bridge)
    uint32_t          monitorCount;     // 0/1 => single-monitor (monitors ignored)
    // Drive redirection (optional, opt-in). Shares ONE local folder with the host as
    // a read/write drive. Both must be non-NULL/non-empty to enable.
    const char*       driveShareName;   // friendly name shown on the host (e.g. "Mac")
    const char*       driveSharePath;   // absolute local folder path
    // F-17: printer redirection (optional, opt-in). 1 => redirect ALL local printers
    // to the host over the same rdpdr channel ("printer" subsystem; CUPS backend on
    // macOS). 0 (default) => zero behavioral change.
    int               printerRedirectionEnabled; // 1/0
    // F-2 experience/performance profile (optional). Swift resolves presets into these
    // concrete values; the bridge applies them verbatim. When experienceSet == 0 the
    // bridge keeps its built-in defaults (network autodetect + eye-candy-off
    // performance flags + 32-bit color) — exactly the pre-F-2 behavior.
    int               experienceSet;        // 1 => apply the exp* fields below
    uint32_t          expConnectionType;    // MS-RDPBCGR CONNECTION_TYPE_* (1..7)
    int               expNetworkAutoDetect; // 1/0: RTT/bandwidth measurement
    uint32_t          expColorDepth;        // bits per pixel: 16/24/32 (else => 32)
    int               expShowWallpaper;     // 1/0
    int               expFontSmoothing;     // 1/0
    int               expFullWindowDrag;    // 1/0: window contents while dragging
    int               expMenuAnimations;    // 1/0
    int               expThemes;            // 1/0: visual styles
    // F-15: remote keyboard layout announced to the server (Windows KBD_* layout id,
    // e.g. 0x407 = German — see freerdp/locale/keyboard.h). 0 == unset: the bridge
    // never touches FreeRDP_KeyboardLayout (FreeRDP's default; pre-F-15 behavior).
    uint32_t          keyboardLayout;
    // PERF-9: per-connection H.264 decoding. Zero == the pre-PERF-9 behaviour.
    // 1 => negotiate AVC420 only (no second chroma stream); server may still fall back
    // to progressive/planar. Halves decode + readback work per frame.
    int               avc444Disabled;
    // 1 => decode AVC420/AVC444 in software even when the linked FreeRDP has
    // VideoToolbox (Tools/build-freerdp.sh, patched to honour a per-thread
    // preference). Ignored by a FreeRDP without that patch (Homebrew: software anyway).
    int               h264HardwareDecodeDisabled;
} RDPBridgeConfig;

// Certificate presented by the server, for TOFU trust decisions (PRD §9.5).
typedef struct {
    const char* host;
    uint32_t    port;
    const char* commonName;
    const char* subject;
    const char* issuer;
    const char* fingerprintSHA256; // hex
    int         hostMismatch;
    int         changed;           // 1 if differs from a previously seen cert (FreeRDP's view)
} RDPBridgeCertInfo;

// --- Callbacks. Invoked on the bridge's internal RDP thread.
//     The engine is responsible for hopping to the main thread for UI. ---

// Connection state changed. errorCode/errorString are meaningful for FAILED.
typedef void (*RDPBridgeStateCb)(void* userCtx, RDPBridgeState state,
                                 uint32_t errorCode, const char* errorString);

// A new framebuffer region is ready. `bgra` points at the FULL framebuffer
// (fullWidth*fullHeight, 4 bytes/px BGRA, `stride` bytes per row); x/y/width/height
// is the region this paint changed (PERF-1) — the rest of the buffer is unchanged
// since the previous call. Valid only during the call — copy/blit synchronously.
typedef void (*RDPBridgeFrameCb)(void* userCtx, const uint8_t* bgra,
                                 uint32_t x, uint32_t y, uint32_t width, uint32_t height,
                                 uint32_t fullWidth, uint32_t fullHeight, uint32_t stride);

// Server resized the remote desktop. Engine should resize its backing layer.
typedef void (*RDPBridgeResizeCb)(void* userCtx, uint32_t width, uint32_t height);

// Certificate verification. Return 1 to accept, 0 to reject the connection.
// The engine implements TOFU + change-warning UI and returns the decision.
typedef int (*RDPBridgeCertCb)(void* userCtx, const RDPBridgeCertInfo* info);

// Remote clipboard text changed (remote -> local). May be NULL.
typedef void (*RDPBridgeClipboardCb)(void* userCtx, const char* utf8Text);

// Remote clipboard image changed (remote -> local). `dib` points at a Windows
// CF_DIB / DIBV5 payload (BITMAP*INFOHEADER + pixel data, no BITMAPFILEHEADER),
// `len` bytes, valid ONLY during the call — copy it synchronously. May be NULL.
typedef void (*RDPBridgeClipboardImageCb)(void* userCtx, const uint8_t* dib, uint32_t len);

// #25: the remote clipboard holds FILES. `blob` is the raw FILEGROUPDESCRIPTORW
// payload (4-byte count + n × 592-byte FILEDESCRIPTORW), valid ONLY during the call —
// copy it synchronously. The Swift side parses/sanitizes it (the bridge only caps the
// size); it then pulls contents on explicit user paste via rdpbridge_request_file_*.
// May be NULL.
typedef void (*RDPBridgeClipboardFilesCb)(void* userCtx, const uint8_t* blob, uint32_t len);

// #25: a FILECONTENTS response for a pull we issued (rdpbridge_request_file_size/range).
// `success` is 1 for CB_RESPONSE_OK, 0 for FAIL (data NULL, len 0). For a SIZE request
// the data is the 8-byte little-endian file size; for RANGE it is the requested bytes.
// `data` is valid ONLY during the call — copy it synchronously. May be NULL.
typedef void (*RDPBridgeFileContentsCb)(void* userCtx, uint32_t streamId, int success,
                                        const uint8_t* data, uint32_t len);

// Remote cursor shape changed: the host wants a new mouse-pointer image. `bgra` is
// width*height, 4 bytes/px (BGRA, straight alpha), valid ONLY during the call — copy it
// synchronously. (hotX, hotY) is the click hotspot in cursor pixels. The engine turns
// this into a platform cursor.
typedef void (*RDPBridgeCursorCb)(void* userCtx, const uint8_t* bgra,
                                  uint32_t width, uint32_t height,
                                  int32_t hotX, int32_t hotY);
// Remote asked to hide the pointer (e.g. video playback). No image.
typedef void (*RDPBridgeCursorHiddenCb)(void* userCtx);
// Remote asked for the default system pointer (plain arrow).
typedef void (*RDPBridgeCursorDefaultCb)(void* userCtx);

typedef struct {
    RDPBridgeStateCb        onState;
    RDPBridgeFrameCb        onFrame;
    RDPBridgeResizeCb       onResize;
    RDPBridgeCertCb         onCertVerify;
    RDPBridgeClipboardCb    onClipboard;
    RDPBridgeClipboardImageCb onClipboardImage; // may be NULL
    RDPBridgeCursorCb       onCursor;        // may be NULL
    RDPBridgeCursorHiddenCb onCursorHidden;  // may be NULL
    RDPBridgeCursorDefaultCb onCursorDefault; // may be NULL
    RDPBridgeClipboardFilesCb onClipboardFiles; // may be NULL (#25)
    RDPBridgeFileContentsCb   onFileContents;   // may be NULL (#25)
} RDPBridgeCallbacks;

// --- Lifecycle ---
RDPBridge*  rdpbridge_create(void* userCtx, RDPBridgeCallbacks cbs);
// Sever the callback link before free: blocks on the callback lock until any
// in-flight RDP-thread callback returns, then nulls userCtx + zeroes the callback
// table so no later callback can touch the (about-to-be-freed) owner. Call from the
// owner's deinit immediately before rdpbridge_free.
void        rdpbridge_detach(RDPBridge* b);
void        rdpbridge_free(RDPBridge* b);

// Begin connecting on a background thread. `passwordUTF8` is an explicitly sized byte
// slice borrowed for this call; the bridge validates and copies it before returning.
// The copy is retained only through the synchronous FreeRDP handshake, then wiped.
// Returns 1 if the thread started. A missing username/password or an invalid credential
// representation emits a FAILED callback and returns 0.
int         rdpbridge_connect(RDPBridge* b, const RDPBridgeConfig* cfg,
                              const uint8_t* passwordUTF8, size_t passwordLength);

// Request a graceful disconnect; the state callback reports DISCONNECTED.
void        rdpbridge_disconnect(RDPBridge* b);

// --- Input (PRD §8.5/§8.6). Coordinates in remote desktop pixels. ---
// flags use RDP PTR_FLAGS_* / mouse semantics, encoded by the engine.
void        rdpbridge_send_pointer(RDPBridge* b, uint16_t flags, uint16_t x, uint16_t y);
// F-9: X1/X2 (back/forward) buttons use the extended-mouse PDU; flags are RDP
// PTR_XFLAGS_* values encoded by the engine.
void        rdpbridge_send_extended_pointer(RDPBridge* b, uint16_t flags, uint16_t x, uint16_t y);
void        rdpbridge_send_wheel(RDPBridge* b, int16_t delta, int horizontal);
// scancode input: RDP KBD_FLAGS_* in flags, hardware scancode in code.
void        rdpbridge_send_scancode(RDPBridge* b, uint16_t flags, uint16_t code);
// unicode fallback for layout-mismatch (PRD §8.6.16).
void        rdpbridge_send_unicode(RDPBridge* b, uint16_t flags, uint16_t code);
// F-27: type a secret into the LIVE session as RDP Unicode keyboard events — the
// lock-screen password-typing feature. Takes the secret as a length-delimited UTF-8
// slice (never a C string, like the connect-time password) so the caller's bytes are
// never assumed NUL-terminated and this function can zero its own working copy.
//
// Unicode events carry the CHARACTER, not a key position, so the remote keyboard
// layout is irrelevant — the scancode mapper would mangle anything outside the
// current layout.
//
// BLOCKS: sleeps `perKeyDelayMs` (clamped 0..100) between key pairs so the Windows
// credential UI doesn't drop input. Call it OFF the main thread. ctxLock is taken and
// released per key, never held across a sleep, so the RDP thread keeps running.
//
// Returns 1 only if every code unit was sent; 0 if the arguments were rejected or the
// session went down partway (a partial secret may have been typed in that case).
int         rdpbridge_type_secret_utf8(RDPBridge* b, const uint8_t* bytes, size_t length,
                                       uint32_t perKeyDelayMs);
// Ctrl+Alt+Del helper.
void        rdpbridge_send_cad(RDPBridge* b);
// Toggle-key (Caps/Num/Scroll Lock) synchronization. `flags` is a bitmask of the
// RDP KBD_SYNC_* values; tells the server the client's current lock states.
void        rdpbridge_send_keyboard_sync(RDPBridge* b, uint32_t flags);
// F-26 "Stay awake": no-op F15 down/up to reset the remote idle timer (no visible
// effect; essentially no application maps F15). Serialized under ctxLock like all input.
void        rdpbridge_send_keepalive(RDPBridge* b);

// --- Dynamic resolution (PRD §8.4, single-display V1) ---
// desktopScaleFactor: Windows DPI % for the new layout (100..500), tracking the
// display the window currently sits on. 0 = keep the connect-time configured value.
void        rdpbridge_request_resize(RDPBridge* b, uint32_t width, uint32_t height,
                                     uint32_t desktopScaleFactor);

// --- Clipboard (local -> remote) ---
void        rdpbridge_set_clipboard_text(RDPBridge* b, const char* utf8Text);
// Set/replace the local clipboard image mirrored to the remote, as a Windows CF_DIB
// (BITMAPINFOHEADER + pixel data, no BITMAPFILEHEADER). Pass NULL/0 to clear. No-op
// unless imageClipboardEnabled was set at connect.
void        rdpbridge_set_clipboard_image(RDPBridge* b, const uint8_t* dib, uint32_t len);

// --- Clipboard file offer (local -> remote, F-8) ---
// One file of a staged offer. Strings are borrowed for the duration of the call only
// (the bridge copies the name and opens its OWN fd on the path).
typedef struct {
    const char* path;   // absolute local path of a REGULAR file (no dir/symlink)
    const char* name;   // sanitized display filename (UTF-8, <= 259 UTF-16 units)
} RDPBridgeFileOfferItem;

// Stage a Mac→Windows file offer: opens each file O_RDONLY|O_NOFOLLOW|O_CLOEXEC,
// snapshots its size (fstat), and announces "FileGroupDescriptorW" so the server can
// pull descriptor + contents (FILECONTENTS_SIZE/RANGE) while the offer stands. The fds
// stay open for the offer's lifetime and are what serve reads (a post-offer path swap
// cannot redirect them). Replaces any previous local clipboard content (text, image, or
// a prior file offer — whose fds are closed). All-or-nothing: returns 1 when every file
// staged, 0 otherwise (nothing staged, nothing leaked). Fails unless
// fileClipboardEnabled was set at connect AND the server negotiated
// CB_STREAM_FILECLIP_ENABLED. Max 64 files.
int  rdpbridge_stage_file_offer(RDPBridge* b, const RDPBridgeFileOfferItem* items,
                                uint32_t count);
// Drop a staged offer (closes its fds) and re-announce without the file format.
// Also happens implicitly on a new text/image/file offer, on disconnect, and in
// rdpbridge_free.
void rdpbridge_clear_file_offer(RDPBridge* b);

// --- Clipboard file pull (remote -> local, #25) ---
// Issue a FILECONTENTS request against the SERVER's announced file list (the one whose
// descriptors arrived via onClipboardFiles). `streamId` is caller-allocated (Swift owns
// a monotonic counter per session); the matching ServerFileContentsResponse comes back
// through onFileContents with the same streamId — the bridge is a stateless
// pass-through for these. Thread-safe (ctxLock + connected gate, like input sends).
// Returns 1 when the request was handed to the channel, 0 otherwise (not connected,
// cliprdr down, file clipboard off, server never negotiated streamed file-clip, or the
// range length exceeds the 8 MiB defensive cap).
int rdpbridge_request_file_size(RDPBridge* b, uint32_t streamId, uint32_t listIndex);
int rdpbridge_request_file_range(RDPBridge* b, uint32_t streamId, uint32_t listIndex,
                                 uint64_t offset, uint32_t length);

// --- Quality stats (polled by the engine, ~1 Hz) ---
// All out-params are optional (may be NULL). `compressedBytes` and `frameCount` are
// monotonic cumulative counters (difference them over time for throughput / FPS).
// `rttMs` / `bwKbps` come from FreeRDP network autodetect and are 0 when unknown.
void        rdpbridge_get_stats(RDPBridge* b, uint64_t* compressedBytes, uint64_t* frameCount,
                                uint32_t* rttMs, uint32_t* bwKbps);

// --- Misc ---
const char* rdpbridge_freerdp_version(void);
// PERF-8: 1 when the linked FreeRDP was built with VideoToolbox H.264 decoding
// (WITH_VIDEOTOOLBOX — Tools/build-freerdp.sh; the Homebrew bottle is 0). When 1,
// FreeRDP's ffmpeg backend uses the hardware decoder for AVC420/AVC444 GFX frames
// automatically and falls back to software only if the VT session can't be created.
int         rdpbridge_h264_hw_decode_available(void);

// --- Bridge-private error codes (delivered via RDPBridgeStateCb on RDPB_STATE_FAILED) ---
// #32: the app (TOFU store / user) rejected the server certificate. This is a code of
// OUR OWN, deliberately outside every FreeRDP error class. The bridge used to report it
// as 0x0002000C — but that value is FreeRDP's ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED
// ("the connection failed at negotiating security settings"), which FreeRDP raises on its
// own for failures that have nothing to do with the certificate. Sharing the number made
// a security-negotiation failure indistinguishable from a rejected certificate: the UI
// said "certificate not trusted" with no certificate to review, and "Review Certificate"
// just re-ran the same failing connect. A code that cannot collide ends that.
#define RDPB_ERROR_CERT_REJECTED 0x7F0C0001u
// FreeRDP asked the bridge for credentials (its AuthenticateEx callback) and there were
// none to give: the password reached NLA empty. Reported as its own code so the engine
// shows the credentials overlay (re-save the password) instead of the "transport layer
// failed" that FreeRDP emits after two doomed NTLM rounds with an empty password.
#define RDPB_ERROR_NO_CREDENTIALS 0x7F0C0002u
// The secret was non-empty at the engine boundary but could not be represented intact
// in FreeRDP settings (embedded NUL, allocation/setter failure, or read-back mismatch).
// This is a local credential-boundary failure, never a network/transport failure.
#define RDPB_ERROR_CREDENTIAL_HANDOFF 0x7F0C0003u
// The caller omitted the account name. NLA cannot build an identity without one, so
// this must return the user to the connection editor before any network thread starts.
#define RDPB_ERROR_INCOMPLETE_CREDENTIALS 0x7F0C0004u

#ifdef __cplusplus
}
#endif

#endif // RDPBRIDGE_H
