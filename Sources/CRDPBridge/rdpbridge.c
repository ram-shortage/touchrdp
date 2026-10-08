// CRDPBridge implementation over libfreerdp-client3 (FreeRDP 3.x).
// Scope: connect + NLA credential injection + certificate TOFU callback + GDI
// software framebuffer + keyboard/mouse input + honest connection-state reporting +
// graceful disconnect. Channels wired: cliprdr (text/images both ways + F-8
// Mac→Windows file offer + #25 remote→Mac file pull), disp (live in-session resize),
// rdpgfx (H.264/GFX), rdpsnd
// (audio playback), rdpdr (opt-in drive redirection). Multi-monitor spanning via the
// initial monitor layout.

// Request the C11 Annex K bounds-checked interfaces (memset_s) where available —
// used by scrub_password's non-elidable zeroing fallback. Must precede <string.h>.
#define __STDC_WANT_LIB_EXT1__ 1

#include "rdpbridge.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/settings.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/pointer.h>
#include <freerdp/codec/color.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <freerdp/event.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/metrics.h>
#include <freerdp/autodetect.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/rdpsnd.h>
#include <freerdp/channels/rdpdr.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <winpr/collections.h>
#include <winpr/string.h>
#include <winpr/user.h>
#include <dlfcn.h>   // PERF-9: optional symbol from the patched from-source FreeRDP
#include <winpr/file.h>
#include <winpr/shell.h>

#include <openssl/bio.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

// F-8: the FILEGROUPDESCRIPTORW wire format is count(4) + n*FILEDESCRIPTORW(592).
// ValidateCore mirrors this size math; keep both honest against winpr/shell.h.
_Static_assert(sizeof(FILEDESCRIPTORW) == 592,
               "FILEDESCRIPTORW layout changed — update FileClipboardOffer math");

// Custom context: first member MUST be rdpClientContext.
typedef struct {
    rdpClientContext common;
    RDPBridge*       bridge;
} BridgeClientContext;

// F-8: one file of the staged Mac→Windows clipboard offer. The fd is opened ONCE at
// stage time (O_RDONLY|O_NOFOLLOW|O_CLOEXEC) and serves every FILECONTENTS read until
// the offer is replaced/cleared — so a post-offer path swap can't redirect reads.
typedef struct {
    char*    name;   // sanitized UTF-8 filename (owned)
    int      fd;     // open for the offer's lifetime; closed on unstage
    uint64_t size;   // fstat snapshot at stage time
} BridgeStagedFile;

struct RDPBridge {
    rdpContext*        ctx;
    pthread_t          thread;
    int                threadStarted;
    RDPBridgeCallbacks cbs;
    void*              userCtx;
    volatile int       running;

    // Threading (A0). `ctxLock` serializes every non-RDP-thread touch of `ctx` and its
    // single-threaded sub-objects (input/metrics/autodetect/transport); `connected`
    // (guarded by ctxLock) gates those touches to the window where the session is live.
    // `cbLock` serializes callback delivery against owner-side teardown: every callback
    // reads userCtx/cbs under cbLock and holds it across the call, so rdpbridge_detach
    // can null them out and know no in-flight callback is still running. Lock order is
    // always ctxLock -> resizeLock/clipLock. `certRejected` is RDP-thread-only.
    pthread_mutex_t    ctxLock;
    int                connected;
    pthread_mutex_t    cbLock;
    int                certRejected;
    int                noCredentials;  // RDP-thread-only: NLA asked for a password we lacked
    int                credentialHandoffFailed; // non-empty secret was lost/corrupted locally

    // copied config (owned)
    char*              hostname;
    char*              username;
    char*              domain;
    char*              password;       // transient: freed after connect completes
    size_t             passwordLength; // exact UTF-8 byte count (excludes terminator)
    char*              gatewayHostname;
    char*              gatewayUsername;
    char*              gatewayDomain;
    char*              gatewayPassword; // F-6: transient; same wipe+free lifecycle as password
    RDPBridgeMonitor*  monitors;        // owned copy of the multi-monitor layout
    uint32_t           monitorCount;    // >1 => multi-monitor session requested
    int                multimonActive;  // set once multimon is actually negotiated
    char*              driveShareName;   // owned; drive redirection (opt-in)
    char*              driveSharePath;   // owned; absolute local folder
    RDPBridgeConfig    cfg;            // shallow copy; string/array ptrs above are the owned ones

    // PERF-9: gdi's original GFX SurfaceCommand handler (interposed to set the
    // per-thread VideoToolbox preference before each command) and the patched
    // library's setter — NULL when the linked FreeRDP is unpatched (e.g. Homebrew).
    pcRdpgfxSurfaceCommand gfxSurfaceCommand;
    void             (*vtPreferenceSetter)(int enabled);

    // Display Control dynamic channel (live in-session resize). `disp` is captured
    // when the "Microsoft::Windows::RDS::DisplayControl" channel connects. Resize
    // requests arrive on the main thread but the channel must be written from the RDP
    // thread, so they're staged here and flushed inside run_loop.
    DispClientContext* disp;
    pthread_mutex_t    resizeLock;
    uint32_t           pendingW, pendingH;  // backing pixels
    uint32_t           pendingSF;           // DesktopScaleFactor %; 0 => connect-time cfg value
    uint32_t           lastSentW, lastSentH; // dedup: skip resending an identical layout
    uint32_t           lastSentSF;
    int                pendingResize;
    // PERF-2: wakes run_loop's WaitForMultipleObjects immediately when a resize or
    // clipboard write is staged from the main thread — without it, a staged request
    // on a quiescent link waits out the full 200 ms poll interval (auto-reset event).
    HANDLE             wakeEvent;

    // Clipboard (cliprdr svc). CF_UNICODETEXT both directions; CF_DIB images both
    // directions when imageClipboardEnabled. `clipOutData` is our current local
    // clipboard text as UTF-16LE (incl. terminator); `clipOutImageData` is the local
    // image as a Windows CF_DIB. Whichever the local clipboard last held is set; the
    // other is cleared (single-item model). Served when the server requests data.
    // Writes come from the main thread; the format-list announce is flushed on the RDP
    // thread (pendingClipAnnounce). `lastReqFormatId` records which format we asked the
    // server for, so the (format-less) data response can be routed (text vs image).
    CliprdrClientContext* cliprdr;
    pthread_mutex_t    clipLock;
    BYTE*              clipOutData;
    size_t             clipOutLen;
    BYTE*              clipOutImageData;   // CF_DIB bytes for the local image
    size_t             clipOutImageLen;
    uint32_t           lastReqFormatId;    // RDP-thread only
    int                pendingClipAnnounce;
    // F-8: staged Mac→Windows file offer (cliprdr "FileGroupDescriptorW"), same
    // single-item model as text/image (a new offer of any kind replaces the others).
    // Guarded by clipLock like the rest of the clip state; `serverFileClipOK` records
    // whether the server negotiated CB_STREAM_FILECLIP_ENABLED (caps callback).
    BridgeStagedFile*  clipOutFiles;
    uint32_t           clipOutFileCount;
    int                serverFileClipOK;
    // #25 (remote→Mac): the SERVER-assigned format id for its "FileGroupDescriptorW"
    // announcement (0 = the current server clipboard holds no files). Written and read
    // only inside cliprdr callbacks (same single-threaded discipline as
    // lastReqFormatId), except the reset on channel disconnect.
    uint32_t           serverFileFormatId;

    // Quality stats. `frameCounter` is bumped on the RDP thread (bridge_end_paint) and
    // sampled on the main thread (rdpbridge_get_stats) — a monotonic counter the engine
    // differences over time for FPS; throughput/RTT come from FreeRDP's own metrics.
    _Atomic uint64_t   frameCounter;
};

static char* dupstr(const char* s) { return (s && *s) ? strdup(s) : NULL; }

// Passwords are passed across the public boundary as a length-delimited UTF-8 slice,
// not as a C string. This preserves the exact byte count and lets us reject embedded
// NULs rather than silently truncating a non-empty Swift String.
static char* dupbytes(const uint8_t* bytes, size_t length) {
    if (!bytes || length == 0 || length == SIZE_MAX) return NULL;
    char* copy = (char*)malloc(length + 1);
    if (!copy) return NULL;
    memcpy(copy, bytes, length);
    copy[length] = '\0';
    return copy;
}

#define TAG "com.touchrdp.bridge"
#define MAX_PASSWORD_BYTES (64u * 1024u)
// ROB-1: log-and-continue for non-fatal feature setup whose return would otherwise be
// dropped. Surfaced via WLog (TOUCHRDP_VERBOSE lowers the threshold); a failed add just
// means that optional feature (audio/drive/resize/gfx/cursor) doesn't arm.
#define CHECK_WARN(expr, msg) do { if (!(expr)) WLog_ERR(TAG, "%s", (msg)); } while (0)

static void secure_bzero(void* p, size_t n);

// ---- Callback funnel (A0) ----
// Every delivery of a callback to the owner goes through cbLock and is guarded by a
// live userCtx. cbLock is held ACROSS the call so rdpbridge_detach (which also takes
// cbLock before nulling userCtx/cbs) can never race a callback into freed storage.
static void emit_state(RDPBridge* b, RDPBridgeState st, uint32_t code, const char* str) {
    pthread_mutex_lock(&b->cbLock);
    if (b->userCtx && b->cbs.onState) b->cbs.onState(b->userCtx, st, code, str);
    pthread_mutex_unlock(&b->cbLock);
}

// ---- FreeRDP callbacks ----

static BOOL bridge_authenticate_ex(freerdp* instance, char** username, char** password,
                                   char** domain, rdp_auth_reason reason) {
    BridgeClientContext* cc = (BridgeClientContext*)instance->context;
    RDPBridge* b = cc ? cc->bridge : NULL;
    const int missingUsername = !username || !*username || !**username;
    const int missingPassword = !password || !*password || !**password;
    const int mainCredentialReason = reason == AUTH_NLA || reason == AUTH_TLS ||
                                     reason == AUTH_RDP || reason == AUTH_RDSTLS;
    // Credentials are pre-set from the Touch-ID-released pair. If FreeRDP asks again
    // during host authentication because either setting became empty, restore BOTH
    // values from the bridge's short-lived private copies. Restoring only the password
    // allowed an empty username to become a nullptr NTLM identity and a misleading
    // transport failure.
    if (mainCredentialReason && (missingUsername || missingPassword)) {
        if (b && username && password && b->username && *b->username &&
            b->password && b->passwordLength > 0) {
            char* restoredUsername = missingUsername ? dupstr(b->username) : NULL;
            char* restoredPassword = missingPassword
                ? dupbytes((const uint8_t*)b->password, b->passwordLength) : NULL;
            char* restoredDomain = (domain && (!*domain || !**domain) && b->domain)
                ? dupstr(b->domain) : NULL;
            if ((missingUsername && !restoredUsername) ||
                (missingPassword && !restoredPassword) ||
                (b->domain && domain && (!*domain || !**domain) && !restoredDomain)) {
                free(restoredUsername);
                if (restoredPassword) {
                    secure_bzero(restoredPassword, b->passwordLength);
                    free(restoredPassword);
                }
                free(restoredDomain);
                b->credentialHandoffFailed = 1;
                return FALSE;
            }
            if (missingUsername) {
                free(*username);
                *username = restoredUsername;
            }
            if (missingPassword) {
                if (*password) {
                    secure_bzero(*password, strlen(*password));
                    free(*password);
                }
                *password = restoredPassword;
            }
            if (restoredDomain) {
                free(*domain);
                *domain = restoredDomain;
            }
            // Belt-and-braces post-condition: the restores above cannot leave either
            // value empty, so reaching here means an invariant broke. Wipe only what
            // actually exists — a check that dereferences the very pointer it is
            // testing for NULL would crash instead of failing closed.
            if (!*username || !**username || !*password || !**password) {
                if (*password) secure_bzero(*password, strlen(*password));
                b->credentialHandoffFailed = 1;
                return FALSE;
            }
            emit_state(b, RDPB_STATE_AUTHENTICATING, 0, "Authenticating");
            return TRUE;
        }
        if (b) b->noCredentials = 1;
        return FALSE;
    }
    // Gateway/smartcard/FIDO callbacks have separate credentials and policies; do not
    // substitute the host's username/password into those flows.
    if (b) emit_state(b, RDPB_STATE_AUTHENTICATING, 0, "Authenticating");
    return TRUE;
}

// Deliver one normalized certificate to the application-owned TOFU store. The bridge
// always asks for session-only acceptance; persistence belongs exclusively to TouchRDP.
static DWORD deliver_certificate(RDPBridge* b, const char* host, UINT16 port,
                                 const char* common_name, const char* subject,
                                 const char* issuer, const char* fingerprint, DWORD flags) {
    if (!b || !fingerprint || !*fingerprint) {
        if (b) b->certRejected = 1;
        return 0; // fail closed (SEC-1)
    }
    RDPBridgeCertInfo info;
    memset(&info, 0, sizeof(info));
    info.host = host; info.port = port; info.commonName = common_name;
    info.subject = subject; info.issuer = issuer; info.fingerprintSHA256 = fingerprint;
    info.hostMismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) ? 1 : 0;
    info.changed      = (flags & VERIFY_CERT_FLAG_CHANGED)  ? 1 : 0;
    // SEC-1: fail closed when no handler is installed (a missing handler must reject,
    // never silently trust). Funnelled through cbLock (A0) like every other callback.
    int accept = 0;
    pthread_mutex_lock(&b->cbLock);
    if (b->userCtx && b->cbs.onCertVerify) accept = b->cbs.onCertVerify(b->userCtx, &info);
    pthread_mutex_unlock(&b->cbLock);
    // LIFE-5: record a user rejection deterministically so run_loop can emit the
    // certificate-rejected error code (not a generic FreeRDP last-error) after connect
    // fails — this is what stops the auto-retry loop on the engine side.
    if (!accept) b->certRejected = 1;
    // Return 2 = accept for this session only, so FreeRDP always defers to our
    // app-layer TOFU store on subsequent connects (we own the trust decision).
    return accept ? 2 : 0;
}

static DWORD bridge_verify_certificate_ex(freerdp* instance, const char* host, UINT16 port,
                                          const char* common_name, const char* subject,
                                          const char* issuer, const char* fingerprint, DWORD flags) {
    BridgeClientContext* cc = (BridgeClientContext*)instance->context;
    return deliver_certificate(cc ? cc->bridge : NULL, host, port, common_name, subject,
                               issuer, fingerprint, flags);
}

// Compatibility fallback for a FreeRDP build that reaches its internal changed-cert
// branch. ExternalCertificateManagement normally bypasses that store entirely, but a
// valid callback here keeps the bridge fail-closed and reviewable if the setting is ever
// unavailable. The application trust store computes "changed" independently too.
static DWORD bridge_verify_changed_certificate_ex(
    freerdp* instance, const char* host, UINT16 port, const char* common_name,
    const char* subject, const char* issuer, const char* new_fingerprint,
    const char* old_subject, const char* old_issuer, const char* old_fingerprint,
    DWORD flags) {
    (void)old_subject; (void)old_issuer; (void)old_fingerprint;
    return bridge_verify_certificate_ex(instance, host, port, common_name, subject, issuer,
                                        new_fingerprint, flags | VERIFY_CERT_FLAG_CHANGED);
}

// OpenSSL's host checker implements SAN-first DNS/IP matching and safe wildcard rules.
// FreeRDP's external-management callback intentionally delegates ALL certificate policy
// to the application, so TouchRDP must preserve the host-mismatch warning itself.
// Returns 1 for a match, 0 for a definite mismatch, and -1 when evaluation itself
// failed. The caller treats -1 as a certificate verification failure, not as a
// user-overridable mismatch.
static int pem_hostname_match(const BYTE* data, size_t length, const char* hostname) {
    if (!data || length == 0 || length > INT_MAX || !hostname || !*hostname) return -1;
    BIO* bio = BIO_new_mem_buf(data, (int)length);
    if (!bio) return -1;
    X509* cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (!cert) return -1;

    // X509_check_ip_asc returns -2 when hostname is not an IP literal. Only then
    // attempt DNS matching. Partial-label wildcards are explicitly forbidden.
    int match = X509_check_ip_asc(cert, hostname, 0);
    if (match == -2) {
        match = X509_check_host(cert, hostname, 0, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS, NULL);
    }
    X509_free(cert);
    if (match < 0) return -1;
    return match == 1 ? 1 : 0;
}

// FreeRDP's intended hook when certificate management is external. Parse the
// length-delimited PEM into the same canonical fingerprint/details used by the legacy
// callback, then feed the existing application-owned TOFU decision.
static int bridge_verify_x509_certificate(freerdp* instance, const BYTE* data, size_t length,
                                          const char* host, UINT16 port, DWORD flags) {
    BridgeClientContext* cc = instance ? (BridgeClientContext*)instance->context : NULL;
    RDPBridge* b = cc ? cc->bridge : NULL;
    // A certificate chain is public data, but cap it so a hostile peer cannot force an
    // unbounded allocation before trust is established.
    const size_t maxCertificateBytes = 4u * 1024u * 1024u;
    if (!b || !data || length == 0 || length > maxCertificateBytes || length == SIZE_MAX) {
        if (b) b->certRejected = 1;
        return 0;
    }

    char* pem = (char*)malloc(length + 1);
    if (!pem) { b->certRejected = 1; return 0; }
    memcpy(pem, data, length);
    pem[length] = '\0';
    rdpCertificate* cert = freerdp_certificate_new_from_pem(pem);
    if (!cert) {
        free(pem);
        b->certRejected = 1;
        return 0;
    }

    size_t commonNameLength = 0;
    char* commonName = freerdp_certificate_get_common_name(cert, &commonNameLength);
    char* subject = freerdp_certificate_get_subject(cert);
    char* issuer = freerdp_certificate_get_issuer(cert);
    char* fingerprint = freerdp_certificate_get_fingerprint(cert);
    const int hostnameMatch = pem_hostname_match(data, length, host);
    if (hostnameMatch < 0) {
        free(fingerprint);
        free(issuer);
        free(subject);
        free(commonName);
        freerdp_certificate_free(cert);
        free(pem);
        b->certRejected = 1;
        return 0;
    }
    if (hostnameMatch == 0) flags |= VERIFY_CERT_FLAG_MISMATCH;

    DWORD accepted = deliver_certificate(b, host, port,
                                         commonName ? commonName : "",
                                         subject ? subject : "",
                                         issuer ? issuer : "",
                                         fingerprint, flags);
    free(fingerprint);
    free(issuer);
    free(subject);
    free(commonName);
    freerdp_certificate_free(cert);
    free(pem);
    return (int)accepted;
}

// PERF-1: reset GDI's invalid-region accumulator at the start of each paint so
// end-paint sees only THIS paint's damage. Without the reset the region grows
// monotonically and every delivery degrades to the full frame.
static BOOL bridge_begin_paint(rdpContext* context) {
    rdpGdi* gdi = context->gdi;
    HGDI_WND hwnd = (gdi && gdi->primary && gdi->primary->hdc) ? gdi->primary->hdc->hwnd : NULL;
    if (hwnd) {
        if (hwnd->invalid) hwnd->invalid->null = TRUE;
        hwnd->ninvalid = 0;
    }
    return TRUE;
}

static BOOL bridge_end_paint(rdpContext* context) {
    BridgeClientContext* cc = (BridgeClientContext*)context;
    RDPBridge* b = cc->bridge;
    rdpGdi* gdi = context->gdi;
    if (!b || !gdi || !gdi->primary_buffer) return TRUE;
    // PERF-1: deliver GDI's invalid bounding box, not the whole frame. `bgra` still
    // points at the FULL framebuffer (the region is an offset into it) — the engine
    // copies only the changed rows, which is what keeps a caret blink from costing a
    // full-resolution memcpy under ctxLock (input sends contend on that lock).
    // Falls back to the full frame when the region isn't available.
    int32_t dx = 0, dy = 0, dw = (int32_t)gdi->width, dh = (int32_t)gdi->height;
    HGDI_WND hwnd = (gdi->primary && gdi->primary->hdc) ? gdi->primary->hdc->hwnd : NULL;
    if (hwnd && hwnd->invalid) {
        if (hwnd->invalid->null) return TRUE;   // paint changed nothing — skip delivery
        dx = hwnd->invalid->x; dy = hwnd->invalid->y;
        dw = hwnd->invalid->w; dh = hwnd->invalid->h;
        if (dx < 0) { dw += dx; dx = 0; }
        if (dy < 0) { dh += dy; dy = 0; }
        if (dx + dw > (int32_t)gdi->width)  dw = (int32_t)gdi->width - dx;
        if (dy + dh > (int32_t)gdi->height) dh = (int32_t)gdi->height - dy;
        if (dw <= 0 || dh <= 0) return TRUE;
    }
    // CONC-7: received-frame count for the quality indicator (FPS). Atomic bump so the
    // main-thread sampler in rdpbridge_get_stats never sees a torn 64-bit value.
    atomic_fetch_add_explicit(&b->frameCounter, 1, memory_order_relaxed);
    pthread_mutex_lock(&b->cbLock);
    if (b->userCtx && b->cbs.onFrame) {
        b->cbs.onFrame(b->userCtx, gdi->primary_buffer,
                       (uint32_t)dx, (uint32_t)dy, (uint32_t)dw, (uint32_t)dh,
                       (uint32_t)gdi->width, (uint32_t)gdi->height, (uint32_t)gdi->stride);
    }
    pthread_mutex_unlock(&b->cbLock);
    return TRUE;
}

static BOOL bridge_desktop_resize(rdpContext* context) {
    BridgeClientContext* cc = (BridgeClientContext*)context;
    RDPBridge* b = cc->bridge;
    rdpGdi* gdi = context->gdi;
    UINT32 w = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (gdi && !gdi_resize(gdi, w, h)) return FALSE;
    if (b) {
        pthread_mutex_lock(&b->cbLock);
        if (b->userCtx && b->cbs.onResize) b->cbs.onResize(b->userCtx, (uint32_t)w, (uint32_t)h);
        pthread_mutex_unlock(&b->cbLock);
    }
    return TRUE;
}

// ---- Display Control dynamic channel (live resize) ----

static uint32_t clamp_even_dim(uint32_t v) {
    if (v < DISPLAY_CONTROL_MIN_MONITOR_WIDTH) v = DISPLAY_CONTROL_MIN_MONITOR_WIDTH;
    if (v > DISPLAY_CONTROL_MAX_MONITOR_WIDTH) v = DISPLAY_CONTROL_MAX_MONITOR_WIDTH;
    return v & ~1u; // monitor layout dimensions must be even
}

// Flush a staged resize to the server. Runs on the RDP thread (run_loop).
static void flush_pending_resize(RDPBridge* b) {
    // Multi-monitor sessions use a fixed layout declared at connect; don't let a
    // window-driven single-monitor resize override it. Keyed on what was actually
    // negotiated (not the request count), so a layout that fell back to single monitor
    // still gets live resize.
    if (b->multimonActive) return;
    pthread_mutex_lock(&b->resizeLock);
    int dirty = b->pendingResize;
    uint32_t w = b->pendingW, h = b->pendingH, reqSF = b->pendingSF;
    b->pendingResize = 0;
    DispClientContext* disp = b->disp;
    pthread_mutex_unlock(&b->resizeLock);

    if (!dirty || !disp || !disp->SendMonitorLayout) return;

    uint32_t cw = clamp_even_dim(w), ch = clamp_even_dim(h);
    // The requester's DesktopScaleFactor tracks the display the window currently sits
    // on (Retina <-> non-Retina moves); fall back to the connect-time HiDPI choice.
    uint32_t sf = reqSF ? reqSF
                        : (b->cfg.desktopScaleFactor ? (uint32_t)b->cfg.desktopScaleFactor : 100);
    if (sf < 100) sf = 100; if (sf > 500) sf = 500;
    // Skip if unchanged from the last layout we sent (updateNSView re-requests on every
    // SwiftUI pass; only a genuine change should hit the wire).
    if (cw == b->lastSentW && ch == b->lastSentH && sf == b->lastSentSF) return;

    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Left = 0;
    layout.Top = 0;
    layout.Width = cw;
    layout.Height = ch;
    layout.Orientation = 0; // ORIENTATION_LANDSCAPE
    layout.DesktopScaleFactor = sf;
    layout.DeviceScaleFactor = 100; // spec permits 100/140/180; 100 is always safe
    // Record the dedup key even if the write fails: staging re-arms on every SwiftUI
    // pass, so NOT recording would hammer a broken-but-present channel every pass.
    // The realistic failure mode — the channel died — is handled by the disconnect
    // handler clearing this key, which makes the reconnect flush genuinely resend.
    UINT rc = disp->SendMonitorLayout(disp, 1, &layout);
    b->lastSentW = cw; b->lastSentH = ch; b->lastSentSF = sf;
    if (rc != CHANNEL_RC_OK)
        WLog_ERR(TAG, "disp: SendMonitorLayout %ux%u sf=%u failed (rc=%u)", cw, ch, sf, rc);
    else
        WLog_INFO(TAG, "disp: sent monitor layout %ux%u sf=%u", cw, ch, sf);
}

// ---- Clipboard (cliprdr svc, text-only) ----

// Upper bound on a single clipboard text payload (UTF-8). 4 MiB is far beyond any
// plausible interactive copy/paste. Caps both the outbound path (set_clipboard_text)
// and, at 2x, the inbound UTF-16LE payload (SEC-3).
#define CLIP_MAX_UTF8_BYTES (4u * 1024u * 1024u)
// Upper bound on a single clipboard image (CF_DIB). 64 MiB is far beyond any plausible
// interactive copy (a 4096x4096 32-bit bitmap is 64 MiB). Caps both directions (SEC-3).
#define CLIP_MAX_IMAGE_BYTES (64u * 1024u * 1024u)
// F-8: staged file-offer bounds. The count cap mirrors FileClipboardOffer.maxFiles in
// Swift (enforced there first; re-enforced here defensively). The chunk cap bounds a
// single server-requested FILECONTENTS_RANGE allocation (SEC-3 spirit — mstsc requests
// 64 KiB chunks; anything past 16 MiB is hostile/broken and is FAILed, not served).
#define CLIP_MAX_OFFER_FILES 64u
#define CLIP_MAX_FILE_CHUNK  (16u * 1024u * 1024u)
// #25 (remote→Mac): inbound caps, SEC-3 spirit. The descriptor blob the SERVER sends
// for its file list is bounded at 4 MiB (~7000 descriptors) before it reaches Swift;
// a FILECONTENTS response for a pull WE issued is bounded at 8 MiB — Swift requests
// ≤ 4 MiB chunks, so anything larger is hostile/broken and is dropped as a failure.
#define CLIP_MAX_INBOUND_FILELIST_BYTES (4u * 1024u * 1024u)
#define CLIP_MAX_PULL_RESPONSE_BYTES    (8u * 1024u * 1024u)
// Local format id we announce for the registered format "FileGroupDescriptorW"
// (MS-RDPECLIP CFSTR_FILEDESCRIPTORW). Any id in the registered range works: the
// server addresses our clipboard by the (id, name) pairs WE announced.
#define BRIDGE_CF_FILEGROUPDESCRIPTORW 0xC004u
static char g_filegroup_format_name[] = "FileGroupDescriptorW";

// Close + free the staged file offer. Caller MUST hold clipLock (or be in a
// single-threaded teardown path — rdpbridge_free after the RDP thread joined).
static void clip_drop_staged_files_locked(RDPBridge* b) {
    for (uint32_t i = 0; i < b->clipOutFileCount; i++) {
        free(b->clipOutFiles[i].name);
        if (b->clipOutFiles[i].fd >= 0) close(b->clipOutFiles[i].fd);
    }
    free(b->clipOutFiles);
    b->clipOutFiles = NULL;
    b->clipOutFileCount = 0;
}

// REQUIRED handshake: tell the server our clipboard capabilities. Without this the
// client/server disagree on format-list encoding (long vs short format names), the
// server's format list fails to parse (cliprdr_read_format_list), and FreeRDP tears
// down the whole connection. Runs on the RDP thread.
static void cliprdr_send_caps(RDPBridge* b) {
    CliprdrClientContext* cliprdr = b->cliprdr;
    if (!cliprdr || !cliprdr->ClientCapabilities) return;

    CLIPRDR_GENERAL_CAPABILITY_SET general;
    memset(&general, 0, sizeof(general));
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    // F-8: streamed file-clip PDUs (FILECONTENTS_*) must be negotiated in the caps
    // exchange or the server never requests file contents. NO_FILE_PATHS because we
    // serve descriptors + streamed contents only, never real local paths. Only added
    // when the connection opted in, so a toggle-off session is bit-identical to before.
    if (b->cfg.fileClipboardEnabled)
        general.generalFlags |= CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS;

    CLIPRDR_CAPABILITIES caps;
    memset(&caps, 0, sizeof(caps));
    caps.common.msgType = CB_CLIP_CAPS;
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
    cliprdr->ClientCapabilities(cliprdr, &caps);
}

// F-8: the server's capabilities — record whether it negotiated streamed file-clip.
// Fires on the channel thread before MonitorReady; guarded by clipLock because the
// announce paths (RDP thread + channel thread) read it.
static UINT bridge_cliprdr_server_capabilities(CliprdrClientContext* ctx,
                                               const CLIPRDR_CAPABILITIES* caps) {
    RDPBridge* b = (RDPBridge*)ctx->custom;
    UINT32 flags = 0;
    // Only the GENERAL set exists in MS-RDPECLIP; read it from the first slot (the
    // same pattern FreeRDP's own file context uses).
    if (caps && caps->cCapabilitiesSets >= 1 && caps->capabilitySets &&
        caps->capabilitySets[0].capabilitySetType == CB_CAPSTYPE_GENERAL) {
        const CLIPRDR_GENERAL_CAPABILITY_SET* gen =
            (const CLIPRDR_GENERAL_CAPABILITY_SET*)caps->capabilitySets;
        flags = gen->generalFlags;
    }
    pthread_mutex_lock(&b->clipLock);
    b->serverFileClipOK = (flags & CB_STREAM_FILECLIP_ENABLED) ? 1 : 0;
    pthread_mutex_unlock(&b->clipLock);
    return CHANNEL_RC_OK;
}

// Announce our current local clipboard formats to the server. Runs on the RDP thread.
static void cliprdr_announce_formats(RDPBridge* b) {
    CliprdrClientContext* cliprdr = b->cliprdr;
    if (!cliprdr || !cliprdr->ClientFormatList) return;

    CLIPRDR_FORMAT formats[3];
    memset(formats, 0, sizeof(formats));
    UINT32 n = 0;

    pthread_mutex_lock(&b->clipLock);
    int haveText  = (b->clipOutData && b->clipOutLen >= 2);
    int haveImage = (b->cfg.imageClipboardEnabled && b->clipOutImageData && b->clipOutImageLen > 0);
    // F-8: only when the connection opted in AND the server negotiated streamed
    // file-clip (rdpbridge_stage_file_offer already refuses otherwise; re-checked here).
    int haveFiles = (b->cfg.fileClipboardEnabled && b->serverFileClipOK &&
                     b->clipOutFileCount > 0);
    pthread_mutex_unlock(&b->clipLock);

    if (haveFiles) {
        formats[n].formatId = BRIDGE_CF_FILEGROUPDESCRIPTORW;
        formats[n].formatName = g_filegroup_format_name;
        n++;
    }
    if (haveText)  { formats[n].formatId = CF_UNICODETEXT; formats[n].formatName = NULL; n++; }
    if (haveImage) { formats[n].formatId = CF_DIB;         formats[n].formatName = NULL; n++; }

    CLIPRDR_FORMAT_LIST list;
    memset(&list, 0, sizeof(list));
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = n;
    list.formats = n ? formats : NULL;
    cliprdr->ClientFormatList(cliprdr, &list);
}

// Server announced new clipboard content → ack, then request the best format we can
// use. Precedence (#25, matching Windows Explorer semantics): FILES win when the
// server offers "FileGroupDescriptorW" and the feature is negotiated+enabled, else
// text if offered, else (when image sync is on) a bitmap. Only one format can be
// requested per response.
static UINT bridge_cliprdr_server_format_list(CliprdrClientContext* ctx,
                                              const CLIPRDR_FORMAT_LIST* list) {
    RDPBridge* b = (RDPBridge*)ctx->custom;
    CLIPRDR_FORMAT_LIST_RESPONSE resp;
    memset(&resp, 0, sizeof(resp));
    resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
    resp.common.msgFlags = CB_RESPONSE_OK;
    if (ctx->ClientFormatListResponse) ctx->ClientFormatListResponse(ctx, &resp);

    BOOL hasText = FALSE;
    UINT32 imgId = 0;   // prefer CF_DIB over CF_DIBV5 when both are offered
    UINT32 fileId = 0;  // #25: server-assigned id for "FileGroupDescriptorW"
    for (UINT32 i = 0; list && i < list->numFormats; i++) {
        UINT32 id = list->formats[i].formatId;
        const char* nm = list->formats[i].formatName;
        if (id == CF_UNICODETEXT || id == CF_TEXT || id == CF_OEMTEXT) hasText = TRUE;
        else if (id == CF_DIB) imgId = CF_DIB;
        else if (id == CF_DIBV5 && imgId == 0) imgId = CF_DIBV5;
        else if (nm && strcmp(nm, g_filegroup_format_name) == 0) fileId = id;
    }

    // #25: remember the server's file-list format id for THIS clipboard generation
    // (0 clears it — a later text-only copy must stop routing responses as files).
    b->serverFileFormatId = fileId;
    int wantFiles = 0;
    if (fileId && b->cfg.fileClipboardEnabled) {
        pthread_mutex_lock(&b->clipLock);
        wantFiles = b->serverFileClipOK;   // only when streamed file-clip was negotiated
        pthread_mutex_unlock(&b->clipLock);
    }

    UINT32 want = 0;
    if (wantFiles) want = fileId;
    else if (hasText) want = CF_UNICODETEXT;
    else if (imgId && b->cfg.imageClipboardEnabled) want = imgId;

    if (want && ctx->ClientFormatDataRequest) {
        b->lastReqFormatId = want;
        CLIPRDR_FORMAT_DATA_REQUEST req;
        memset(&req, 0, sizeof(req));
        req.common.msgType = CB_FORMAT_DATA_REQUEST;
        req.requestedFormatId = want;
        ctx->ClientFormatDataRequest(ctx, &req);
    }
    return CHANNEL_RC_OK;
}

// F-8: build the FILEGROUPDESCRIPTORW blob for the staged offer. Descriptors are
// assembled UNDER clipLock (memory-only, bounded at 64 entries); serialization + the
// channel send happen OUTSIDE the lock (CONC-6). Returns a malloc'd blob or NULL.
static BYTE* clip_build_filegroup_blob(RDPBridge* b, UINT32* outLen) {
    FILEDESCRIPTORW* descs = NULL;
    UINT32 nfiles = 0;
    int nameFailed = 0;

    pthread_mutex_lock(&b->clipLock);
    if (b->cfg.fileClipboardEnabled && b->clipOutFileCount > 0 &&
        b->clipOutFileCount <= CLIP_MAX_OFFER_FILES) {
        descs = (FILEDESCRIPTORW*)calloc(b->clipOutFileCount, sizeof(FILEDESCRIPTORW));
        if (descs) {
            nfiles = b->clipOutFileCount;
            for (UINT32 i = 0; i < nfiles; i++) {
                const BridgeStagedFile* f = &b->clipOutFiles[i];
                FILEDESCRIPTORW* d = &descs[i];
                // Attributes + size are the fields we can vouch for; PROGRESSUI asks
                // Explorer for the standard copy-progress dialog.
                d->dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_PROGRESSUI;
                d->dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
                d->nFileSizeHigh = (DWORD)(f->size >> 32);
                d->nFileSizeLow  = (DWORD)(f->size & 0xFFFFFFFFu);
                // Swift pre-sanitizes to <= 259 UTF-16 units; a conversion failure
                // here means corrupt staging — fail the whole response, never send a
                // descriptor with a garbage name.
                if (ConvertUtf8ToWChar(f->name, d->cFileName,
                                       ARRAYSIZE(d->cFileName)) < 0) {
                    nameFailed = 1;
                    break;
                }
                d->cFileName[ARRAYSIZE(d->cFileName) - 1] = 0;
            }
        }
    }
    pthread_mutex_unlock(&b->clipLock);

    BYTE* blob = NULL;
    UINT32 blobLen = 0;
    if (descs && nfiles > 0 && !nameFailed &&
        cliprdr_serialize_file_list(descs, nfiles, &blob, &blobLen) == CHANNEL_RC_OK) {
        *outLen = blobLen;
    } else {
        free(blob);
        blob = NULL;
        *outLen = 0;
    }
    free(descs);
    return blob;
}

// Server wants OUR clipboard data → respond with our UTF-16LE text, CF_DIB image, or
// the F-8 FILEGROUPDESCRIPTORW file list (or FAIL).
static UINT bridge_cliprdr_server_format_data_request(CliprdrClientContext* ctx,
                                                      const CLIPRDR_FORMAT_DATA_REQUEST* req) {
    RDPBridge* b = (RDPBridge*)ctx->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE resp;
    memset(&resp, 0, sizeof(resp));
    resp.common.msgType = CB_FORMAT_DATA_RESPONSE;

    // F-8: the server asked for the staged file offer's descriptor list.
    if (req && req->requestedFormatId == BRIDGE_CF_FILEGROUPDESCRIPTORW) {
        UINT32 blobLen = 0;
        BYTE* blob = clip_build_filegroup_blob(b, &blobLen);
        if (blob && blobLen > 0) {
            resp.common.msgFlags = CB_RESPONSE_OK;
            resp.common.dataLen = blobLen;
            resp.requestedFormatData = blob;
        } else {
            resp.common.msgFlags = CB_RESPONSE_FAIL;
        }
        if (ctx->ClientFormatDataResponse) ctx->ClientFormatDataResponse(ctx, &resp);
        free(blob);
        return CHANNEL_RC_OK;
    }

    // CONC-6: snapshot the current clipboard payload into a private copy UNDER clipLock,
    // then release the lock before the channel send. Copying (not sending the live
    // buffer) avoids both holding the lock across network I/O and a UAF should a
    // concurrent set_clipboard_* free the source buffer mid-send.
    BYTE* copy = NULL;
    UINT32 len = 0;
    pthread_mutex_lock(&b->clipLock);
    if (req) {
        const BYTE* src = NULL;
        if (req->requestedFormatId == CF_UNICODETEXT && b->clipOutData && b->clipOutLen >= 2) {
            src = b->clipOutData; len = (UINT32)b->clipOutLen;
        } else if (req->requestedFormatId == CF_DIB && b->cfg.imageClipboardEnabled &&
                   b->clipOutImageData && b->clipOutImageLen > 0) {
            src = b->clipOutImageData; len = (UINT32)b->clipOutImageLen;
        }
        if (src && len > 0) {
            copy = (BYTE*)malloc(len);
            if (copy) memcpy(copy, src, len);
            else len = 0;
        }
    }
    pthread_mutex_unlock(&b->clipLock);

    if (copy) {
        resp.common.msgFlags = CB_RESPONSE_OK;
        resp.common.dataLen = len;
        resp.requestedFormatData = copy;
    } else {
        resp.common.msgFlags = CB_RESPONSE_FAIL;
        resp.common.dataLen = 0;
        resp.requestedFormatData = NULL;
    }
    if (ctx->ClientFormatDataResponse) ctx->ClientFormatDataResponse(ctx, &resp);
    free(copy);
    return CHANNEL_RC_OK;
}

// Server delivered the data we requested. The response carries no format id, so route
// by what we last asked for: text → UTF-16LE → UTF-8 → app; CF_DIB/V5 → raw bytes → app
// (the engine decodes the DIB into a CGImage for the local pasteboard).
static UINT bridge_cliprdr_server_format_data_response(CliprdrClientContext* ctx,
                                                       const CLIPRDR_FORMAT_DATA_RESPONSE* resp) {
    RDPBridge* b = (RDPBridge*)ctx->custom;
    if (!resp || !(resp->common.msgFlags & CB_RESPONSE_OK) ||
        !resp->requestedFormatData || resp->common.dataLen < 2) {
        return CHANNEL_RC_OK;
    }
    // #25: we asked for the server's FILEGROUPDESCRIPTORW list. Cap it (SEC-3: a
    // hostile server can't force a huge allocation — 4 MiB ≈ 7000 descriptors) and
    // hand the RAW blob to Swift, which parses + sanitizes it (safer than C parsing).
    if (b->serverFileFormatId != 0 && b->lastReqFormatId == b->serverFileFormatId) {
        if (resp->common.dataLen > CLIP_MAX_INBOUND_FILELIST_BYTES) return CHANNEL_RC_OK;
        if (b->cfg.fileClipboardEnabled) {
            pthread_mutex_lock(&b->cbLock);
            if (b->userCtx && b->cbs.onClipboardFiles)
                b->cbs.onClipboardFiles(b->userCtx, resp->requestedFormatData,
                                        resp->common.dataLen);
            pthread_mutex_unlock(&b->cbLock);
        }
        return CHANNEL_RC_OK;
    }
    if (b->lastReqFormatId == CF_DIB || b->lastReqFormatId == CF_DIBV5) {
        // SEC-3: reject an oversized server-controlled image before it reaches the owner
        // (mirrors the outbound cap). A hostile server can't force a huge allocation.
        if (resp->common.dataLen > CLIP_MAX_IMAGE_BYTES) return CHANNEL_RC_OK;
        if (b->cfg.imageClipboardEnabled) {
            pthread_mutex_lock(&b->cbLock);
            if (b->userCtx && b->cbs.onClipboardImage)
                b->cbs.onClipboardImage(b->userCtx, resp->requestedFormatData, resp->common.dataLen);
            pthread_mutex_unlock(&b->cbLock);
        }
        return CHANNEL_RC_OK;
    }
    // SEC-3: cap the inbound UTF-16LE text before converting/allocating. 2x the UTF-8
    // cap bounds the worst-case widening while staying well beyond any real paste.
    if (resp->common.dataLen > 2u * CLIP_MAX_UTF8_BYTES) return CHANNEL_RC_OK;
    size_t wlen = resp->common.dataLen / sizeof(WCHAR);
    size_t u8len = 0;
    char* utf8 = ConvertWCharNToUtf8Alloc((const WCHAR*)resp->requestedFormatData, wlen, &u8len);
    if (utf8) {
        pthread_mutex_lock(&b->cbLock);
        if (b->userCtx && b->cbs.onClipboard) b->cbs.onClipboard(b->userCtx, utf8);
        pthread_mutex_unlock(&b->cbLock);
        free(utf8);
    }
    return CHANNEL_RC_OK;
}

// F-8: the server is pulling an offered file — its 8-byte size (FILECONTENTS_SIZE) or
// a byte range (FILECONTENTS_RANGE). Runs on the cliprdr channel thread. CONC-6
// discipline: the staged entry is snapshotted under clipLock via dup() of its fd, then
// the lock is RELEASED before the disk read and the channel send — a concurrent
// unstage (close) can't invalidate the dup, and the lock is never held across I/O.
static UINT bridge_cliprdr_server_file_contents_request(
        CliprdrClientContext* ctx, const CLIPRDR_FILE_CONTENTS_REQUEST* req) {
    RDPBridge* b = (RDPBridge*)ctx->custom;
    CLIPRDR_FILE_CONTENTS_RESPONSE resp;
    memset(&resp, 0, sizeof(resp));
    resp.common.msgType = CB_FILECONTENTS_RESPONSE;
    resp.common.msgFlags = CB_RESPONSE_FAIL;
    resp.streamId = req ? req->streamId : 0;

    int dupfd = -1;
    uint64_t fsize = 0;
    if (req && b->cfg.fileClipboardEnabled) {
        pthread_mutex_lock(&b->clipLock);
        if (req->listIndex < b->clipOutFileCount) {
            fsize = b->clipOutFiles[req->listIndex].size;
            dupfd = dup(b->clipOutFiles[req->listIndex].fd);
        }
        pthread_mutex_unlock(&b->clipLock);
    }

    BYTE* buf = NULL;
    int ok = 0;
    if (dupfd >= 0) {
        if (req->dwFlags & FILECONTENTS_SIZE) {
            // 8-byte UINT64 little-endian file size.
            buf = (BYTE*)malloc(8);
            if (buf) {
                for (int i = 0; i < 8; i++) buf[i] = (BYTE)(fsize >> (8 * i));
                resp.cbRequested = 8;
                ok = 1;
            }
        } else if (req->dwFlags & FILECONTENTS_RANGE) {
            uint64_t pos = ((uint64_t)req->nPositionHigh << 32) | req->nPositionLow;
            UINT32 want = req->cbRequested;
            // SEC-3 spirit: a hostile chunk size can't force a huge allocation, and a
            // position past the staged size is refused rather than trusted.
            if (want <= CLIP_MAX_FILE_CHUNK && pos <= fsize) {
                if ((uint64_t)want > fsize - pos) want = (UINT32)(fsize - pos);
                buf = (BYTE*)malloc(want ? want : 1);
                if (buf) {
                    size_t total = 0;
                    ok = 1;
                    while (total < want) {
                        ssize_t got = pread(dupfd, buf + total, want - total,
                                            (off_t)(pos + total));
                        if (got < 0) {
                            if (errno == EINTR) continue;
                            ok = 0;      // read error → FAIL
                            break;
                        }
                        if (got == 0) break;   // file shrank since staging: EOF short-read
                        total += (size_t)got;
                    }
                    resp.cbRequested = (UINT32)total;
                }
            }
        }
        close(dupfd);
    }

    if (ok) {
        resp.common.msgFlags = CB_RESPONSE_OK;
        resp.requestedData = buf;
    } else {
        resp.cbRequested = 0;
        resp.requestedData = NULL;
    }
    if (ctx->ClientFileContentsResponse) ctx->ClientFileContentsResponse(ctx, &resp);
    free(buf);
    return CHANNEL_RC_OK;
}

// #25: the server answered a FILECONTENTS request WE issued (a Swift-driven pull for
// a file promise being fulfilled in Finder). Stateless pass-through: forward
// (streamId, success, bytes) to Swift, which matches it to its pending-request table.
// SEC-3: an oversized payload (Swift never requests more than 4 MiB; 8 MiB is the
// defensive ceiling) is reported as a FAILURE, never delivered.
static UINT bridge_cliprdr_server_file_contents_response(
        CliprdrClientContext* ctx, const CLIPRDR_FILE_CONTENTS_RESPONSE* resp) {
    RDPBridge* b = (RDPBridge*)ctx->custom;
    if (!resp || !b->cfg.fileClipboardEnabled) return CHANNEL_RC_OK;
    int ok = (resp->common.msgFlags & CB_RESPONSE_OK) ? 1 : 0;
    const BYTE* data = resp->requestedData;
    uint32_t len = resp->cbRequested;
    if (!ok || !data || len > CLIP_MAX_PULL_RESPONSE_BYTES) {
        ok = 0;
        data = NULL;
        len = 0;
    }
    pthread_mutex_lock(&b->cbLock);
    if (b->userCtx && b->cbs.onFileContents)
        b->cbs.onFileContents(b->userCtx, resp->streamId, ok, data, len);
    pthread_mutex_unlock(&b->cbLock);
    return CHANNEL_RC_OK;
}

// Server ready → advertise our current clipboard formats.
static UINT bridge_cliprdr_monitor_ready(CliprdrClientContext* ctx,
                                         const CLIPRDR_MONITOR_READY* ready) {
    (void)ready;
    RDPBridge* b = (RDPBridge*)ctx->custom;
    cliprdr_send_caps(b);        // must precede the format list
    cliprdr_announce_formats(b);
    return CHANNEL_RC_OK;
}

static void cliprdr_attach(RDPBridge* b, CliprdrClientContext* cliprdr) {
    b->cliprdr = cliprdr;
    cliprdr->custom = b;
    cliprdr->MonitorReady = bridge_cliprdr_monitor_ready;
    cliprdr->ServerCapabilities = bridge_cliprdr_server_capabilities;   // F-8
    cliprdr->ServerFormatList = bridge_cliprdr_server_format_list;
    cliprdr->ServerFormatDataRequest = bridge_cliprdr_server_format_data_request;
    cliprdr->ServerFormatDataResponse = bridge_cliprdr_server_format_data_response;
    cliprdr->ServerFileContentsRequest = bridge_cliprdr_server_file_contents_request; // F-8
    cliprdr->ServerFileContentsResponse = bridge_cliprdr_server_file_contents_response; // #25
}

// ---- PERF-9: per-connection VideoToolbox preference ----
// FreeRDP creates each GFX surface's H264_CONTEXT lazily inside its SurfaceCommand
// handler and, once built WITH_VIDEOTOOLBOX, uses the hardware unconditionally. The
// from-source build carries a small patch (Tools/freerdp-patches) that exports a
// per-THREAD preference the decoder consults at creation. Wrapping SurfaceCommand and
// setting that preference immediately before delegating to gdi makes the choice per
// call — hence per connection — on whatever thread the dynamic channel delivers.
// The setter is looked up with dlsym so the bridge still links against an unpatched
// (Homebrew) FreeRDP, where the toggle is moot: that build decodes in software anyway.
static UINT bridge_gfx_surface_command(RdpgfxClientContext* gfx, const RDPGFX_SURFACE_COMMAND* cmd) {
    rdpGdi* gdi = gfx ? (rdpGdi*)gfx->custom : NULL;
    BridgeClientContext* cc = gdi ? (BridgeClientContext*)gdi->context : NULL;
    RDPBridge* b = cc ? cc->bridge : NULL;
    if (!b || !b->gfxSurfaceCommand) return ERROR_INTERNAL_ERROR;
    if (b->vtPreferenceSetter)
        b->vtPreferenceSetter(b->cfg.h264HardwareDecodeDisabled ? 0 : 1);
    return b->gfxSurfaceCommand(gfx, cmd);
}

static void bridge_on_channel_connected(void* context, const ChannelConnectedEventArgs* e) {
    BridgeClientContext* cc = (BridgeClientContext*)context;
    RDPBridge* b = cc ? cc->bridge : NULL;
    if (!b || !e || !e->name) return;
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        cliprdr_attach(b, (CliprdrClientContext*)e->pInterface);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&b->resizeLock);
        b->disp = (DispClientContext*)e->pInterface;
        // Push the current desired size once the channel is up. Do NOT clear the
        // dedup key here: some server stacks recycle this channel after applying a
        // layout, so clearing on connect resends the just-applied layout and can loop
        // (apply -> recycle -> resend -> ...). The key is cleared on channel
        // DISCONNECT instead, so a genuinely new channel still gets one real send.
        if (b->pendingW && b->pendingH) b->pendingResize = 1;
        pthread_mutex_unlock(&b->resizeLock);
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // Bind the Graphics Pipeline (H.264/progressive) to the GDI surface so decoded
        // frames land in the primary buffer that bridge_end_paint delivers.
        rdpGdi* gdi = b->ctx ? b->ctx->gdi : NULL;
        RdpgfxClientContext* gfx = (RdpgfxClientContext*)e->pInterface;
        if (gdi) {
            CHECK_WARN(gdi_graphics_pipeline_init(gdi, gfx),
                       "rdpgfx: gdi_graphics_pipeline_init failed (GFX disabled)");
            // PERF-9: interpose on gdi's handler so each session's decoder is created
            // with its own hardware-decode preference (see bridge_gfx_surface_command).
            // Installed before any surface command can arrive on this channel.
            if (!b->vtPreferenceSetter) {
                b->vtPreferenceSetter = (void (*)(int))dlsym(
                    RTLD_DEFAULT, "freerdp_h264_set_thread_videotoolbox_preference");
            }
            if (gfx->SurfaceCommand && gfx->SurfaceCommand != bridge_gfx_surface_command) {
                b->gfxSurfaceCommand = gfx->SurfaceCommand;
                gfx->SurfaceCommand = bridge_gfx_surface_command;
            }
            if (b->cfg.h264HardwareDecodeDisabled && !b->vtPreferenceSetter &&
                rdpbridge_h264_hw_decode_available()) {
                WLog_WARN(TAG, "PERF-9: hardware decode is off for this connection but the "
                               "linked FreeRDP lacks the thread-preference patch — it will "
                               "still use VideoToolbox (rebuild with Tools/build-freerdp.sh)");
            }
        }
    }
}

static void bridge_on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e) {
    BridgeClientContext* cc = (BridgeClientContext*)context;
    RDPBridge* b = cc ? cc->bridge : NULL;
    if (!b || !e || !e->name) return;
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        b->cliprdr = NULL;
        // #25: the server's announced file list dies with the channel too.
        b->serverFileFormatId = 0;
        // F-8: the negotiated caps die with the channel; a reconnect renegotiates.
        pthread_mutex_lock(&b->clipLock);
        b->serverFileClipOK = 0;
        pthread_mutex_unlock(&b->clipLock);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&b->resizeLock);
        b->disp = NULL;
        // The channel died: anything "sent" on it may not have been applied. Clearing
        // the dedup key here (not on connect) means a replacement channel gets exactly
        // one real resend of the desired layout — a send that's a no-op if the server
        // still has it, and cannot loop, because an identical layout causes no mode
        // change and therefore no further channel recycling.
        b->lastSentW = 0; b->lastSentH = 0; b->lastSentSF = 0;
        pthread_mutex_unlock(&b->resizeLock);
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        rdpGdi* gdi = b->ctx ? b->ctx->gdi : NULL;
        if (gdi) gdi_graphics_pipeline_uninit(gdi, (RdpgfxClientContext*)e->pInterface);
    }
}

// ---- Remote pointer (mouse cursor shape) ----
// The host streams cursor-shape updates over the pointer PDUs. FreeRDP calls these
// graphics callbacks; we convert each cursor to BGRA once (New), cache it on the
// pointer, and hand it to the engine when it becomes active (Set). SetNull hides the
// pointer; SetDefault restores the plain arrow. Registered in bridge_post_connect.

// Subclass of rdpPointer: FreeRDP allocates `size` bytes, so our cache lives inline.
typedef struct {
    rdpPointer pointer;   // MUST be first
    BYTE*      bgra;      // converted image, width*height*4 (BGRA), or NULL
    UINT32     width, height;
    INT32      hotX, hotY;
} BridgePointer;

static BOOL bridge_Pointer_New(rdpContext* context, rdpPointer* pointer) {
    if (!context || !pointer) return FALSE;
    BridgePointer* bp = (BridgePointer*)pointer;
    // ROB-2: define our cache fields up-front so any early return leaves bp->bgra a
    // determinate NULL (bridge_Pointer_Free must never free indeterminate memory).
    bp->bgra = NULL; bp->width = 0; bp->height = 0; bp->hotX = 0; bp->hotY = 0;
    rdpGdi* gdi = context->gdi;
    if (!gdi) return FALSE;
    const UINT32 w = pointer->width, h = pointer->height;
    if (!w || !h || w > 384 || h > 384) return TRUE;  // ignore implausible sizes
    bp->bgra = (BYTE*)calloc(1, (size_t)w * h * 4);
    if (!bp->bgra) return FALSE;
    if (!freerdp_image_copy_from_pointer_data(
            bp->bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, w, h,
            pointer->xorMaskData, pointer->lengthXorMask,
            pointer->andMaskData, pointer->lengthAndMask,
            pointer->xorBpp, &gdi->palette)) {
        free(bp->bgra);
        bp->bgra = NULL;
        return TRUE;  // non-fatal: just no custom shape for this one
    }
    bp->width = w; bp->height = h;
    bp->hotX = (INT32)pointer->xPos; bp->hotY = (INT32)pointer->yPos;
    return TRUE;
}

static void bridge_Pointer_Free(rdpContext* context, rdpPointer* pointer) {
    (void)context;
    if (!pointer) return;
    BridgePointer* bp = (BridgePointer*)pointer;
    free(bp->bgra);
    bp->bgra = NULL;
}

static BOOL bridge_Pointer_Set(rdpContext* context, rdpPointer* pointer) {
    BridgeClientContext* cc = (BridgeClientContext*)context;
    RDPBridge* b = cc ? cc->bridge : NULL;
    BridgePointer* bp = (BridgePointer*)pointer;
    if (b && bp && bp->bgra) {
        pthread_mutex_lock(&b->cbLock);
        if (b->userCtx && b->cbs.onCursor)
            b->cbs.onCursor(b->userCtx, bp->bgra, bp->width, bp->height, bp->hotX, bp->hotY);
        pthread_mutex_unlock(&b->cbLock);
    }
    return TRUE;
}

static BOOL bridge_Pointer_SetNull(rdpContext* context) {
    BridgeClientContext* cc = (BridgeClientContext*)context;
    RDPBridge* b = cc ? cc->bridge : NULL;
    if (b) {
        pthread_mutex_lock(&b->cbLock);
        if (b->userCtx && b->cbs.onCursorHidden) b->cbs.onCursorHidden(b->userCtx);
        pthread_mutex_unlock(&b->cbLock);
    }
    return TRUE;
}

static BOOL bridge_Pointer_SetDefault(rdpContext* context) {
    BridgeClientContext* cc = (BridgeClientContext*)context;
    RDPBridge* b = cc ? cc->bridge : NULL;
    if (b) {
        pthread_mutex_lock(&b->cbLock);
        if (b->userCtx && b->cbs.onCursorDefault) b->cbs.onCursorDefault(b->userCtx);
        pthread_mutex_unlock(&b->cbLock);
    }
    return TRUE;
}

static BOOL bridge_Pointer_SetPosition(rdpContext* context, UINT32 x, UINT32 y) {
    // Server-driven pointer warps are not applied to the local cursor (the Mac owns
    // pointer position; we send moves to the host, not the reverse). No-op.
    (void)context; (void)x; (void)y;
    return TRUE;
}

static void register_pointer(rdpContext* context) {
    if (!context || !context->graphics) return;
    rdpPointer proto = { 0 };
    proto.size        = sizeof(BridgePointer);
    proto.New         = bridge_Pointer_New;
    proto.Free        = bridge_Pointer_Free;
    proto.Set         = bridge_Pointer_Set;
    proto.SetNull     = bridge_Pointer_SetNull;
    proto.SetDefault  = bridge_Pointer_SetDefault;
    proto.SetPosition = bridge_Pointer_SetPosition;
    graphics_register_pointer(context->graphics, &proto);
}

static BOOL bridge_pre_connect(freerdp* instance) {
    BridgeClientContext* cc = (BridgeClientContext*)instance->context;
    RDPBridge* b = cc ? cc->bridge : NULL;
    if (b) {
        const char* username = freerdp_settings_get_string(instance->context->settings,
                                                           FreeRDP_Username);
        const char* password = freerdp_settings_get_string(instance->context->settings,
                                                           FreeRDP_Password);
        const size_t usernameLength = username ? strlen(username) : 0;
        const size_t passwordLength = password ? strlen(password) : 0;
        const size_t expectedUsernameLength = b->username ? strlen(b->username) : 0;
        const int usernameMatches = username && b->username && expectedUsernameLength > 0 &&
                                    usernameLength == expectedUsernameLength &&
                                    memcmp(username, b->username, usernameLength) == 0;
        const int passwordMatches = password && b->password && b->passwordLength > 0 &&
                                    passwordLength == b->passwordLength &&
                                    memcmp(password, b->password, passwordLength) == 0;
        WLog_INFO(TAG, "credential handoff before FreeRDP consistency: userPresent=%d "
                       "userBytes=%" PRIuz " expectedUserBytes=%" PRIuz " userMatch=%d "
                       "passwordPresent=%d passwordBytes=%" PRIuz
                       " expectedPasswordBytes=%" PRIuz " passwordMatch=%d",
                  username != NULL, usernameLength, expectedUsernameLength, usernameMatches,
                  password != NULL, passwordLength, b->passwordLength, passwordMatches);
        if (!usernameMatches || !passwordMatches) {
            b->credentialHandoffFailed = 1;
            return FALSE;
        }
    }
    // Load channel addins (drdynvc + the Display Control "disp" dynamic channel that
    // apply_settings registered). Required for live in-session resize.
    if (!freerdp_client_load_addins(instance->context->channels, instance->context->settings))
        return FALSE;
    if (b) emit_state(b, RDPB_STATE_NEGOTIATING, 0, "Negotiating");
    return TRUE;
}

static BOOL bridge_post_connect(freerdp* instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    // Receive remote cursor-shape updates and surface them to the engine as a native
    // cursor (must come after gdi_init: the palette is needed to decode the masks).
    register_pointer(instance->context);
    rdpUpdate* update = instance->context->update;
    update->BeginPaint    = bridge_begin_paint;   // PERF-1: per-paint damage tracking
    update->EndPaint      = bridge_end_paint;
    update->DesktopResize = bridge_desktop_resize;
    BridgeClientContext* cc = (BridgeClientContext*)instance->context;
    if (cc && cc->bridge) emit_state(cc->bridge, RDPB_STATE_CONNECTED, 0, "Connected");
    return TRUE;
}

// ClientNew runs during freerdp_client_context_new (before bridge ptr is wired).
static BOOL bridge_client_new(freerdp* instance, rdpContext* context) {
    (void)context;
    instance->PreConnect          = bridge_pre_connect;
    instance->PostConnect         = bridge_post_connect;
    instance->AuthenticateEx      = bridge_authenticate_ex;
    instance->VerifyCertificateEx = bridge_verify_certificate_ex;
    instance->VerifyChangedCertificateEx = bridge_verify_changed_certificate_ex;
    instance->VerifyX509Certificate = bridge_verify_x509_certificate;
    return TRUE;
}
static void bridge_client_free(freerdp* instance, rdpContext* context) {
    (void)instance; (void)context;
}

// ---- Connection thread ----

static BOOL password_setting_matches(const RDPBridge* b, const rdpSettings* settings) {
    if (!b || !settings || !b->password || b->passwordLength == 0) return FALSE;
    const char* value = freerdp_settings_get_string(settings, FreeRDP_Password);
    if (!value) return FALSE;
    const size_t length = strlen(value);
    return length == b->passwordLength && memcmp(value, b->password, length) == 0;
}

static BOOL apply_settings(RDPBridge* b) {
    rdpSettings* s = b->ctx->settings;
    const RDPBridgeConfig* c = &b->cfg;

    // TouchRDP owns the sole persistent TOFU store. This instructs FreeRDP to bypass
    // ~/.config/freerdp/server entirely and route every certificate through our X.509
    // callback, so stale/corrupt PEMs from another FreeRDP client cannot affect us.
    if (!freerdp_settings_set_bool(s, FreeRDP_ExternalCertificateManagement, TRUE)) {
        WLog_ERR(TAG, "failed to enable external certificate management");
        return FALSE;
    }

    freerdp_settings_set_string(s, FreeRDP_ServerHostname, b->hostname);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, c->port ? c->port : 3389);
    if (!b->username || !*b->username ||
        !freerdp_settings_set_string(s, FreeRDP_Username, b->username)) {
        b->credentialHandoffFailed = 1;
        return FALSE;
    }
    if (b->domain)   freerdp_settings_set_string(s, FreeRDP_Domain, b->domain);
    // An empty password is deliberately NOT set: FreeRDP treats "" as a usable
    // credential and burns an NTLM round on it, whereas NULL makes it ask us via
    // AuthenticateEx, where the NLA case is refused with RDPB_ERROR_NO_CREDENTIALS.
    if (b->password && b->passwordLength > 0) {
        if (!freerdp_settings_set_string(s, FreeRDP_Password, b->password) ||
            !password_setting_matches(b, s)) {
            b->credentialHandoffFailed = 1;
            return FALSE;
        }
    } else {
        b->noCredentials = 1;
        return FALSE;
    }

    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth,  c->width  ? c->width  : 1280);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, c->height ? c->height : 800);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    if (c->desktopScaleFactor)
        freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, c->desktopScaleFactor);

    // F-15: remote keyboard layout preset (Windows KBD_* id). 0 == unset (.auto):
    // leave FreeRDP_KeyboardLayout at the library default — pre-F-15 behavior.
    if (c->keyboardLayout)
        freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, c->keyboardLayout);

    // Multi-monitor: declare the local screen layout to the host. The server then
    // delivers one framebuffer covering the bounding box of all monitors (DesktopWidth/
    // Height above is that union). The sorted setter validates + orders the layout and
    // populates MonitorCount/MonitorDefArray. Live window-resize is disabled in this
    // mode (the layout is fixed at connect — see flush_pending_resize).
    if (b->monitorCount > 1 && b->monitors) {
        rdpMonitor* defs = (rdpMonitor*)calloc(b->monitorCount, sizeof(rdpMonitor));
        if (!defs) {
            // ROB-5: signal the degrade instead of silently falling back to single monitor.
            WLog_ERR(TAG, "multimon: calloc of %u monitor defs failed; using single monitor",
                     (unsigned)b->monitorCount);
        }
        if (defs) {
            for (uint32_t i = 0; i < b->monitorCount; i++) {
                const RDPBridgeMonitor* m = &b->monitors[i];
                defs[i].x = m->x;
                defs[i].y = m->y;
                // Clamp each monitor to the protocol's even min/max so degenerate or
                // zero-size screen geometry can't produce an invalid layout.
                defs[i].width = (INT32)clamp_even_dim((uint32_t)(m->width > 0 ? m->width : 0));
                defs[i].height = (INT32)clamp_even_dim((uint32_t)(m->height > 0 ? m->height : 0));
                defs[i].is_primary = m->isPrimary ? 1 : 0;
                defs[i].orig_screen = i;
                uint32_t sf = m->scaleFactor ? m->scaleFactor : 100;
                if (sf < 100) sf = 100;
                if (sf > 500) sf = 500;
                defs[i].attributes.desktopScaleFactor = sf;
                defs[i].attributes.deviceScaleFactor = 100;
                defs[i].attributes.orientation = 0; // landscape
            }
            freerdp_settings_set_bool(s, FreeRDP_UseMultimon, TRUE);
            freerdp_settings_set_monitor_def_array_sorted(s, defs, b->monitorCount);
            free(defs);
            b->multimonActive = 1; // only now is live single-monitor resize suppressed
        }
    }

    // Security negotiation (NLA preferred).
    switch (c->security) {
        case RDPB_SEC_NLA:
            freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, TRUE);
            freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
            freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
            break;
        case RDPB_SEC_TLS:
            freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE);
            freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
            freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
            break;
        case RDPB_SEC_RDP:
            freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE);
            freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, FALSE);
            freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, TRUE);
            freerdp_settings_set_bool(s, FreeRDP_UseRdpSecurityLayer, TRUE);
            break;
    }

    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, c->clipboardEnabled ? TRUE : FALSE);

    // Audio playback (rdpsnd). Setting AudioPlayback alone isn't enough — the rdpsnd
    // static channel must be registered so freerdp_client_load_addins (pre_connect)
    // loads it. macOS uses the CoreAudio/AudioQueue backend ("sys:mac"). Playback only:
    // we never set AudioCapture, so the microphone is never redirected. Non-fatal: if
    // the channel can't be added we still connect, just without sound.
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, c->audioEnabled ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AudioCapture, FALSE);
    if (c->audioEnabled) {
        const char* rdpsnd_argv[] = { RDPSND_CHANNEL_NAME, "sys:mac" };
        CHECK_WARN(freerdp_client_add_static_channel(s, 2, rdpsnd_argv),
                   "audio: failed to add rdpsnd channel (connecting without sound)");
    }

    // Drive redirection (rdpdr). Opt-in: shares ONE explicit local folder read/write
    // with the host. Adding the device channel requires DeviceRedirection enabled; the
    // rdpdr channel is then loaded automatically by freerdp_client_load_addins.
    if (b->driveSharePath && *b->driveSharePath) {
        freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, TRUE);
        const char* name = (b->driveShareName && *b->driveShareName) ? b->driveShareName : "Mac";
        const char* drive_argv[] = { "drive", name, b->driveSharePath };
        CHECK_WARN(freerdp_client_add_device_channel(s, 3, drive_argv),
                   "drive: failed to add rdpdr device channel (redirection disabled)");
    }

    // F-17: printer redirection (rdpdr "printer" subsystem; CUPS backend on macOS).
    // Opt-in. Passing just {"printer"} (no name) mirrors the CLI's bare /printer:
    // freerdp_client_add_device_channel sets FreeRDP_RedirectPrinters +
    // FreeRDP_DeviceRedirection TRUE and adds a nameless RDPDR_DTYP_PRINT device;
    // printer_DeviceServiceEntry then EnumPrinters()s and registers ALL local CUPS
    // printers (verified in FreeRDP 3.28 client/common/cmdline.c and
    // channels/printer/client/printer_main.c; Homebrew bottle links libcups).
    // Print jobs flow host -> client only; nothing local becomes readable.
    if (c->printerRedirectionEnabled) {
        freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, TRUE);
        const char* printer_argv[] = { "printer" };
        CHECK_WARN(freerdp_client_add_device_channel(s, 1, printer_argv),
                   "printer: failed to add rdpdr printer device (redirection disabled)");
    }

    // ---- Bandwidth / responsiveness (LAN + poor WAN) ----
    // Graphics Pipeline with H.264: stream the screen as video instead of raw
    // bitmaps — by far the biggest win over a slow link. The server falls back
    // automatically if it lacks GFX. AVC444 carries crisp text; progressive is the
    // non-H.264 fallback codec.
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE);
    // PERF-9: AVC444 is two H.264 streams per frame (luma + full-res chroma aux) —
    // two decodes, two hardware readbacks. Per-connection opt-out keeps AVC420 (4:2:0).
    const BOOL avc444 = c->avc444Disabled ? FALSE : TRUE;
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, avc444);
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, avc444);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxThinClient, FALSE);
    // Codec fallbacks for servers without GFX (still much smaller than raw bitmaps).
    freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_NSCodec, TRUE);
    // Bulk compression + bitmap caching reduce retransmission.
    freerdp_settings_set_bool(s, FreeRDP_CompressionEnabled, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_BitmapCacheEnabled, TRUE);
    // Frame-ack flow control: cap in-flight frames so a slow link can't build a
    // backlog of stale frames (keeps input latency low rather than buffering video).
    freerdp_settings_set_uint32(s, FreeRDP_FrameAcknowledge, 2);
    // ---- F-2 experience profile vs. built-in defaults ----
    if (c->experienceSet) {
        // Swift resolved a per-connection experience profile; apply it verbatim.
        // Connection type is the MS-RDPBCGR link-speed hint; autodetect (when on)
        // additionally measures RTT/bandwidth so the server can refine encoding.
        freerdp_settings_set_bool(s, FreeRDP_NetworkAutoDetect,
                                  c->expNetworkAutoDetect ? TRUE : FALSE);
        freerdp_settings_set_uint32(s, FreeRDP_ConnectionType, c->expConnectionType);
        uint32_t depth = c->expColorDepth;
        if (depth != 16 && depth != 24 && depth != 32) depth = 32;
        freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, depth);
        // Set the individual UI-feature bools AND the aggregate PerformanceFlags,
        // kept consistent, so the outcome is the same whether the core sends the
        // aggregate or recomputes it via freerdp_performance_flags_make().
        freerdp_settings_set_bool(s, FreeRDP_DisableWallpaper,
                                  c->expShowWallpaper ? FALSE : TRUE);
        freerdp_settings_set_bool(s, FreeRDP_AllowFontSmoothing,
                                  c->expFontSmoothing ? TRUE : FALSE);
        freerdp_settings_set_bool(s, FreeRDP_DisableFullWindowDrag,
                                  c->expFullWindowDrag ? FALSE : TRUE);
        freerdp_settings_set_bool(s, FreeRDP_DisableMenuAnims,
                                  c->expMenuAnimations ? FALSE : TRUE);
        freerdp_settings_set_bool(s, FreeRDP_DisableThemes,
                                  c->expThemes ? FALSE : TRUE);
        // Cursor shadow/settings stay disabled in every profile: the client renders
        // the pointer locally (cursor-shape callbacks), so they only add churn.
        UINT32 perf = PERF_DISABLE_CURSOR_SHADOW | PERF_DISABLE_CURSORSETTINGS;
        if (!c->expShowWallpaper)  perf |= PERF_DISABLE_WALLPAPER;
        if (c->expFontSmoothing)   perf |= PERF_ENABLE_FONT_SMOOTHING;
        if (!c->expFullWindowDrag) perf |= PERF_DISABLE_FULLWINDOWDRAG;
        if (!c->expMenuAnimations) perf |= PERF_DISABLE_MENUANIMATIONS;
        if (!c->expThemes)         perf |= PERF_DISABLE_THEMING;
        freerdp_settings_set_uint32(s, FreeRDP_PerformanceFlags, perf);
    } else {
        // Defaults (profile "Automatic" / pre-F-2 connections):
        // let RDP measure RTT/bandwidth so the server adapts its encoding, and drop
        // server-side eye candy that wastes bandwidth (wallpaper, window-drag
        // contents, menu/cursor animations, themes).
        freerdp_settings_set_bool(s, FreeRDP_NetworkAutoDetect, TRUE);
        freerdp_settings_set_uint32(s, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT);
        freerdp_settings_set_uint32(s, FreeRDP_PerformanceFlags,
            PERF_DISABLE_WALLPAPER | PERF_DISABLE_FULLWINDOWDRAG |
            PERF_DISABLE_MENUANIMATIONS | PERF_DISABLE_THEMING |
            PERF_DISABLE_CURSOR_SHADOW | PERF_DISABLE_CURSORSETTINGS);
    }

    // Dynamic resolution: enable dynamic channels + the Display Control + Graphics
    // Pipeline channels, and register their client addins.
    freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    const char* disp_argv[] = { "disp" };
    CHECK_WARN(freerdp_client_add_dynamic_channel(s, 1, disp_argv),
               "resize: failed to add disp dynamic channel (live resize disabled)");
    const char* gfx_argv[] = { "rdpgfx" };
    CHECK_WARN(freerdp_client_add_dynamic_channel(s, 1, gfx_argv),
               "gfx: failed to add rdpgfx dynamic channel (Graphics Pipeline disabled)");

    if (c->gatewayEnabled) {
        freerdp_settings_set_bool(s, FreeRDP_GatewayEnabled, TRUE);
        if (b->gatewayHostname) freerdp_settings_set_string(s, FreeRDP_GatewayHostname, b->gatewayHostname);
        if (c->gatewayPort) freerdp_settings_set_uint32(s, FreeRDP_GatewayPort, c->gatewayPort);
        if (b->gatewayUsername) freerdp_settings_set_string(s, FreeRDP_GatewayUsername, b->gatewayUsername);
        else if (b->username)   freerdp_settings_set_string(s, FreeRDP_GatewayUsername, b->username);
        if (b->gatewayDomain) freerdp_settings_set_string(s, FreeRDP_GatewayDomain, b->gatewayDomain);
        // F-6: a separate gateway password when supplied; otherwise the gateway
        // authenticates with the MAIN credentials (explicitly, so the behavior does
        // not depend on FreeRDP fallback defaults). Both copies are wiped after
        // freerdp_connect (see run_loop).
        if (b->gatewayPassword)  freerdp_settings_set_string(s, FreeRDP_GatewayPassword, b->gatewayPassword);
        else if (b->password)    freerdp_settings_set_string(s, FreeRDP_GatewayPassword, b->password);
    }

    if (c->tcpConnectTimeoutMs)
        freerdp_settings_set_uint32(s, FreeRDP_TcpConnectTimeout, c->tcpConnectTimeoutMs);
    return TRUE;
}

// SEC-2: non-elidable memory wipe. A plain memset over about-to-be-freed memory can be
// optimized away; prefer explicit_bzero, else C11 Annex K memset_s, else a volatile loop.
static void secure_bzero(void* p, size_t n) {
    if (!p || n == 0) return;
#if defined(__STDC_LIB_EXT1__) || defined(__APPLE__)
    memset_s(p, n, 0, n);
#elif defined(__GLIBC__) || defined(__OpenBSD__) || defined(__FreeBSD__)
    explicit_bzero(p, n);
#else
    volatile unsigned char* v = (volatile unsigned char*)p;
    while (n--) *v++ = 0;
#endif
}

// Wipe and free the transient password(s) ASAP. Covers the main password and the
// F-6 gateway password — both share the same SEC-2 dup+zero lifecycle.
static void scrub_password(RDPBridge* b) {
    if (b->password) {
        secure_bzero(b->password, b->passwordLength);
        free(b->password);
        b->password = NULL;
    }
    b->passwordLength = 0;
    if (b->gatewayPassword) {
        secure_bzero(b->gatewayPassword, strlen(b->gatewayPassword));
        free(b->gatewayPassword);
        b->gatewayPassword = NULL;
    }
}

// FreeRDP owns separate settings copies. Wipe those buffers before asking the settings
// API to release them, on both successful and early-failure paths.
static void scrub_settings_passwords(RDPBridge* b) {
    if (!b || !b->ctx || !b->ctx->settings) return;
    const char* password = freerdp_settings_get_string(b->ctx->settings, FreeRDP_Password);
    if (password) secure_bzero((void*)password, strlen(password));
    freerdp_settings_set_string(b->ctx->settings, FreeRDP_Password, NULL);

    const char* gatewayPassword =
        freerdp_settings_get_string(b->ctx->settings, FreeRDP_GatewayPassword);
    if (gatewayPassword) secure_bzero((void*)gatewayPassword, strlen(gatewayPassword));
    freerdp_settings_set_string(b->ctx->settings, FreeRDP_GatewayPassword, NULL);
}

static void* run_loop(void* arg) {
    RDPBridge* b = (RDPBridge*)arg;
    freerdp* instance = b->ctx->instance;

    emit_state(b, RDPB_STATE_CONNECTING, 0, "Connecting");
    if (!apply_settings(b)) {
        scrub_password(b);
        scrub_settings_passwords(b);
        if (b->credentialHandoffFailed) {
            emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_CREDENTIAL_HANDOFF,
                       "The password could not be handed to FreeRDP intact. Re-save it and retry.");
        } else if (b->noCredentials) {
            emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_NO_CREDENTIALS,
                       "No password was available for sign-in: the saved password for this connection is empty. Re-save it to continue.");
        } else {
            emit_state(b, RDPB_STATE_FAILED, 0x00020001u,
                       "Could not configure the RDP connection securely");
        }
        return NULL;
    }

    // Capture the Display Control channel interface when it connects (live resize).
    PubSub_SubscribeChannelConnected(b->ctx->pubSub, bridge_on_channel_connected);
    PubSub_SubscribeChannelDisconnected(b->ctx->pubSub, bridge_on_channel_disconnected);

    BOOL ok = freerdp_connect(instance);
    // The NLA/gateway handshakes have consumed the passwords by now; scrub our copies.
    scrub_password(b);
    // SEC-2: zero FreeRDP's own settings copies in place before releasing them (set_string
    // NULL frees but does not wipe). CredSSP/NLA internal copies remain unreachable from
    // the bridge — documented residual risk requiring a FreeRDP-side change. The gateway
    // password (F-6) gets the identical treatment.
    scrub_settings_passwords(b);

    if (!ok) {
        // ROB-3: drop our channel-event subscriptions on the early-failure path too.
        PubSub_UnsubscribeChannelConnected(b->ctx->pubSub, bridge_on_channel_connected);
        PubSub_UnsubscribeChannelDisconnected(b->ctx->pubSub, bridge_on_channel_disconnected);
        // LIFE-5: a user-rejected certificate is reported with OUR bridge-private code so
        // the engine classifies it as .certificateRejected (excluded from auto-retry). #32:
        // never a FreeRDP code — FreeRDP reports its own failures in that space, and the
        // engine must be able to tell "we rejected the cert" from "FreeRDP failed".
        if (b->certRejected) {
            emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_CERT_REJECTED, "Server certificate rejected");
        } else if (b->credentialHandoffFailed) {
            emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_CREDENTIAL_HANDOFF,
                       "The password could not be handed to FreeRDP intact. Re-save it and retry.");
        } else if (b->noCredentials) {
            emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_NO_CREDENTIALS,
                       "No password was available for sign-in: the saved password for this connection is empty. Re-save it to continue.");
        } else {
            UINT32 err = freerdp_get_last_error(b->ctx);
            emit_state(b, RDPB_STATE_FAILED, err, freerdp_get_last_error_string(err));
        }
        return NULL;
    }

    // CONC-2: the session is live — open the gate so main-thread input/stats may touch ctx.
    pthread_mutex_lock(&b->ctxLock);
    b->connected = 1;
    pthread_mutex_unlock(&b->ctxLock);

    // Event loop. The WAIT (WaitForMultipleObjects, <=200 ms) stays OUTSIDE ctxLock so a
    // main-thread input send is never blocked for a wait quantum; only the processing
    // step (the two flushes + freerdp_check_event_handles) runs under ctxLock, serialized
    // against the main-thread ctx touches. Lock order is ctxLock -> resizeLock/clipLock.
    int reportedFailure = 0;
    while (b->running && !freerdp_shall_disconnect_context(b->ctx)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        DWORD count = freerdp_get_event_handles(b->ctx, handles, MAXIMUM_WAIT_OBJECTS);
        if (count == 0) {
            // ROB-4: no event handles is a hard error, not a benign silent exit.
            emit_state(b, RDPB_STATE_FAILED, 0, "No event handles available");
            break;
        }
        // PERF-2: our stage-wake event joins the wait set so resize/clipboard staging
        // interrupts the wait instead of riding the 200 ms timeout.
        if (b->wakeEvent && count < MAXIMUM_WAIT_OBJECTS) handles[count++] = b->wakeEvent;
        DWORD status = WaitForMultipleObjects(count, handles, FALSE, 200 /*ms*/);
        if (status == WAIT_FAILED) break;
        // PERF-2: clear the wake BEFORE reading the staged flags below. A staging that
        // lands after this reset either has its flag read by this pass, or re-signals the
        // event and is flushed by the next one — never a lost wakeup, at worst one extra
        // no-op iteration. Resetting after the flag read could drop a wakeup instead.
        if (b->wakeEvent) ResetEvent(b->wakeEvent);

        pthread_mutex_lock(&b->ctxLock);
        // Flush any window-driven resize request to the server (RDP-thread side).
        flush_pending_resize(b);
        // Flush a pending local-clipboard announce (set from the main thread).
        pthread_mutex_lock(&b->clipLock);
        int announce = b->pendingClipAnnounce;
        b->pendingClipAnnounce = 0;
        pthread_mutex_unlock(&b->clipLock);
        if (announce) cliprdr_announce_formats(b);
        BOOL evOk = freerdp_check_event_handles(b->ctx);
        pthread_mutex_unlock(&b->ctxLock);

        if (!evOk) {
            UINT32 err = freerdp_get_last_error(b->ctx);
            if (err) {
                emit_state(b, RDPB_STATE_FAILED, err, freerdp_get_last_error_string(err));
                reportedFailure = 1;
            }
            break;
        }
    }

    // Teardown: close the gate + disconnect under ctxLock so no main-thread input/stats
    // call can touch ctx while FreeRDP tears it down.
    pthread_mutex_lock(&b->ctxLock);
    // A server-ended session (another client took it over, remote logoff, admin
    // disconnect, idle timeout) leaves the loop through shall_disconnect with no last
    // error, so it used to surface as a plain "Disconnected" and got auto-reconnected
    // like a network drop — which, against another auto-reconnecting client, loops.
    // Report the server's error info instead. Skipped when WE stopped the session.
    const UINT32 errInfo = freerdp_error_info(instance);
    pthread_mutex_unlock(&b->ctxLock);
    if (b->running && !reportedFailure && errInfo != ERRINFO_SUCCESS) {
        emit_state(b, RDPB_STATE_FAILED, MAKE_FREERDP_ERROR(ERRINFO, errInfo),
                   freerdp_get_error_info_string(errInfo));
    }
    pthread_mutex_lock(&b->ctxLock);
    b->connected = 0;
    freerdp_disconnect(instance);
    pthread_mutex_unlock(&b->ctxLock);

    // ROB-3: unsubscribe the channel-event handlers before the context is freed.
    PubSub_UnsubscribeChannelConnected(b->ctx->pubSub, bridge_on_channel_connected);
    PubSub_UnsubscribeChannelDisconnected(b->ctx->pubSub, bridge_on_channel_disconnected);

    // F-8: the session is down — the file offer dies with it (fds closed, no leak).
    pthread_mutex_lock(&b->clipLock);
    clip_drop_staged_files_locked(b);
    b->serverFileClipOK = 0;
    pthread_mutex_unlock(&b->clipLock);

    emit_state(b, RDPB_STATE_DISCONNECTED, 0, "Disconnected");
    return NULL;
}

// ---- Public API ----

static int g_wlog_inited = 0;
static void init_wlog_once(void) {
    if (g_wlog_inited) return;
    g_wlog_inited = 1;
    wLog* root = WLog_GetRoot();
    // Default quiet; set TOUCHRDP_VERBOSE=1 to surface the channel/codec handshake
    // (cliprdr, disp, rdpgfx, rdpsnd) for diagnostics.
    DWORD level = getenv("TOUCHRDP_VERBOSE") ? WLOG_INFO : WLOG_WARN;
    if (root) WLog_SetLogLevel(root, level);
}

RDPBridge* rdpbridge_create(void* userCtx, RDPBridgeCallbacks cbs) {
    init_wlog_once();
    RDPBridge* b = (RDPBridge*)calloc(1, sizeof(RDPBridge));
    if (!b) return NULL;
    b->userCtx = userCtx;
    b->cbs = cbs;
    pthread_mutex_init(&b->ctxLock, NULL);
    pthread_mutex_init(&b->cbLock, NULL);
    pthread_mutex_init(&b->resizeLock, NULL);
    pthread_mutex_init(&b->clipLock, NULL);
    // PERF-2: MANUAL-reset + explicit ResetEvent in run_loop. WinPR does not implement
    // auto-reset events ("auto-reset events not yet implemented"), so a FALSE here would
    // create an event that never clears — leaving it permanently signaled, which turns
    // the loop's 200 ms wait into a busy spin. NULL is tolerated everywhere below.
    b->wakeEvent = CreateEventA(NULL, TRUE, FALSE, NULL);

    RDP_CLIENT_ENTRY_POINTS ep;
    memset(&ep, 0, sizeof(ep));
    ep.Size = sizeof(ep);
    ep.Version = RDP_CLIENT_INTERFACE_VERSION;
    ep.ContextSize = sizeof(BridgeClientContext);
    ep.ClientNew = bridge_client_new;
    ep.ClientFree = bridge_client_free;

    b->ctx = freerdp_client_context_new(&ep);
    if (!b->ctx) { free(b); return NULL; }
    ((BridgeClientContext*)b->ctx)->bridge = b;
    return b;
}

int rdpbridge_connect(RDPBridge* b, const RDPBridgeConfig* cfg,
                      const uint8_t* passwordUTF8, size_t passwordLength) {
    if (!b || !cfg || b->threadStarted) return 0;
    if (!cfg->username || !*cfg->username) {
        b->noCredentials = 1;
        emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_INCOMPLETE_CREDENTIALS,
                   "No username was available for sign-in. Edit the connection and enter one before retrying.");
        return 0;
    }
    // FreeRDP stores passwords as C strings. Reject any representation that would be
    // truncated or is implausibly large before copying config or starting a thread.
    if (passwordLength > MAX_PASSWORD_BYTES ||
        (passwordLength > 0 && (!passwordUTF8 || memchr(passwordUTF8, '\0', passwordLength)))) {
        b->credentialHandoffFailed = 1;
        emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_CREDENTIAL_HANDOFF,
                   "The saved password could not be represented safely. Re-save it and retry.");
        return 0;
    }
    if (passwordLength == 0) {
        b->noCredentials = 1;
        emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_NO_CREDENTIALS,
                   "No password was available for sign-in: the saved password for this connection is empty. Re-save it to continue.");
        return 0;
    }

    b->cfg = *cfg; // shallow copy
    b->hostname        = dupstr(cfg->hostname);
    b->username        = dupstr(cfg->username);
    b->domain          = dupstr(cfg->domain);
    b->password        = dupbytes(passwordUTF8, passwordLength);
    b->passwordLength  = passwordLength;
    if (passwordLength > 0 && !b->password) {
        b->passwordLength = 0;
        b->credentialHandoffFailed = 1;
        emit_state(b, RDPB_STATE_FAILED, RDPB_ERROR_CREDENTIAL_HANDOFF,
                   "The password could not be copied for sign-in. Re-save it and retry.");
        return 0;
    }
    b->gatewayHostname = dupstr(cfg->gatewayHostname);
    b->gatewayUsername = dupstr(cfg->gatewayUsername);
    b->gatewayDomain   = dupstr(cfg->gatewayDomain);
    b->gatewayPassword = dupstr(cfg->gatewayPassword);  // F-6: wiped by scrub_password
    b->driveShareName  = dupstr(cfg->driveShareName);
    b->driveSharePath  = dupstr(cfg->driveSharePath);
    // Deep-copy the monitor layout (borrowed during the call only).
    if (cfg->monitors && cfg->monitorCount > 0) {
        b->monitors = (RDPBridgeMonitor*)calloc(cfg->monitorCount, sizeof(RDPBridgeMonitor));
        if (b->monitors) {
            memcpy(b->monitors, cfg->monitors, cfg->monitorCount * sizeof(RDPBridgeMonitor));
            b->monitorCount = cfg->monitorCount;
        }
    }
    // Null out borrowed pointers in the copy so we never read freed/foreign memory.
    b->cfg.hostname = b->cfg.username = b->cfg.domain = NULL;
    b->cfg.gatewayHostname = b->cfg.gatewayUsername = b->cfg.gatewayDomain = NULL;
    b->cfg.gatewayPassword = NULL;
    b->cfg.monitors = NULL;
    b->cfg.driveShareName = b->cfg.driveSharePath = NULL;

    b->running = 1;
    if (pthread_create(&b->thread, NULL, run_loop, b) != 0) {
        b->running = 0;
        // SEC-4: the RDP thread never started, so nothing will consume/scrub the dup'd
        // password. Wipe it now rather than leaving plaintext alive until rdpbridge_free.
        scrub_password(b);
        return 0;
    }
    b->threadStarted = 1;
    return 1;
}

void rdpbridge_disconnect(RDPBridge* b) {
    if (!b) return;
    b->running = 0;
    // Cross-thread interrupt: intentionally OUTSIDE ctxLock (it is the designed
    // wake-up for the RDP thread; locking it would deadlock the running event loop).
    if (b->ctx && b->threadStarted) freerdp_abort_connect_context(b->ctx);
}

// CONC-4: sever the callback link before free. Takes cbLock, so it blocks until any
// in-flight RDP-thread callback has returned, then nulls userCtx + zeroes cbs. After
// this returns, no callback can ever reach the (about-to-be-freed) owner again — this
// is what makes handing the bridge an unretained owner pointer safe.
void rdpbridge_detach(RDPBridge* b) {
    if (!b) return;
    pthread_mutex_lock(&b->cbLock);
    b->userCtx = NULL;
    memset(&b->cbs, 0, sizeof(b->cbs));
    pthread_mutex_unlock(&b->cbLock);
}

void rdpbridge_free(RDPBridge* b) {
    if (!b) return;
    rdpbridge_disconnect(b);
    if (b->threadStarted) pthread_join(b->thread, NULL);
    scrub_password(b);
    free(b->hostname); free(b->username); free(b->domain);
    free(b->gatewayHostname); free(b->gatewayUsername); free(b->gatewayDomain);
    free(b->driveShareName); free(b->driveSharePath);
    free(b->monitors);
    if (b->ctx) freerdp_client_context_free(b->ctx);
    pthread_mutex_destroy(&b->ctxLock);
    pthread_mutex_destroy(&b->cbLock);
    pthread_mutex_destroy(&b->resizeLock);
    free(b->clipOutData);
    free(b->clipOutImageData);
    // F-8: belt-and-braces — a connect that never reached run_loop's teardown (or a
    // stage racing free) still closes its fds here. RDP thread is joined; no lock needed.
    clip_drop_staged_files_locked(b);
    pthread_mutex_destroy(&b->clipLock);
    if (b->wakeEvent) CloseHandle(b->wakeEvent);  // PERF-2
    free(b);
}

// CONC-2: every input sender touches ctx->input (a single-threaded FreeRDP object the
// RDP thread also drives) from the main thread, so each takes ctxLock and checks the
// `connected` gate — outside the live window (pre-connect / mid-teardown) the send is a
// no-op rather than a race/UAF. The RDP thread only holds ctxLock for its short
// processing step (not the wait), so these rarely block.
void rdpbridge_send_pointer(RDPBridge* b, uint16_t flags, uint16_t x, uint16_t y) {
    if (!b) return;
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input)
        freerdp_input_send_mouse_event(b->ctx->input, flags, x, y);
    pthread_mutex_unlock(&b->ctxLock);
}
// F-9: X1/X2 (back/forward) buttons travel in a separate extended-mouse PDU
// (PTR_XFLAGS_*), not the standard pointer event. Same ctxLock + connected gate and
// coordinate handling as rdpbridge_send_pointer above.
void rdpbridge_send_extended_pointer(RDPBridge* b, uint16_t flags, uint16_t x, uint16_t y) {
    if (!b) return;
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input)
        freerdp_input_send_extended_mouse_event(b->ctx->input, flags, x, y);
    pthread_mutex_unlock(&b->ctxLock);
}
void rdpbridge_send_wheel(RDPBridge* b, int16_t delta, int horizontal) {
    if (!b) return;
    UINT16 flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
    UINT16 d = (UINT16)(delta < 0 ? (PTR_FLAGS_WHEEL_NEGATIVE | (UINT16)(delta & WheelRotationMask))
                                  : (UINT16)(delta & WheelRotationMask));
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input)
        freerdp_input_send_mouse_event(b->ctx->input, (UINT16)(flags | d), 0, 0);
    pthread_mutex_unlock(&b->ctxLock);
}
void rdpbridge_send_scancode(RDPBridge* b, uint16_t flags, uint16_t code) {
    if (!b) return;
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input)
        freerdp_input_send_keyboard_event(b->ctx->input, flags, (UINT8)code);
    pthread_mutex_unlock(&b->ctxLock);
}
void rdpbridge_send_unicode(RDPBridge* b, uint16_t flags, uint16_t code) {
    if (!b) return;
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input)
        freerdp_input_send_unicode_keyboard_event(b->ctx->input, flags, code);
    pthread_mutex_unlock(&b->ctxLock);
}
int rdpbridge_type_secret_utf8(RDPBridge* b, const uint8_t* bytes, size_t length,
                               uint32_t perKeyDelayMs) {
    if (!b || !bytes || length == 0 || length > MAX_PASSWORD_BYTES) return 0;
    // UTF-16 never needs more code units than the UTF-8 byte count (a 4-byte sequence
    // becomes a 2-unit surrogate pair), so length+1 always fits the result + terminator.
    const size_t cap = length + 1;
    WCHAR* wide = (WCHAR*)calloc(cap, sizeof(WCHAR));
    if (!wide) return 0;

    int allSent = 0;
    const SSIZE_T units = ConvertUtf8NToWChar((const char*)bytes, length, wide, cap);
    if (units > 0) {
        if (perKeyDelayMs > 100) perKeyDelayMs = 100;
        allSent = 1;
        for (SSIZE_T i = 0; i < units; i++) {
            // Lock per key, never across the sleep below: holding ctxLock for the whole
            // secret would stall the RDP thread (and every other input send) for the
            // duration of the typing.
            pthread_mutex_lock(&b->ctxLock);
            const int live = (b->connected && b->ctx && b->ctx->input) ? 1 : 0;
            if (live) {
                // Surrogate pairs go out in order as two events, which is what the
                // protocol expects; the server reassembles them.
                freerdp_input_send_unicode_keyboard_event(b->ctx->input, 0, (UINT16)wide[i]);
                freerdp_input_send_unicode_keyboard_event(b->ctx->input, KBD_FLAGS_RELEASE,
                                                          (UINT16)wide[i]);
            }
            pthread_mutex_unlock(&b->ctxLock);
            if (!live) { allSent = 0; break; }   // session died mid-secret
            if (perKeyDelayMs) usleep(perKeyDelayMs * 1000);
        }
    }

    // SEC-2 discipline: wipe our decoded copy before releasing it. The caller's UTF-8
    // bytes are its own to manage.
    secure_bzero(wide, cap * sizeof(WCHAR));
    free(wide);
    return allSent;
}
void rdpbridge_send_keyboard_sync(RDPBridge* b, uint32_t flags) {
    if (!b) return;
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input)
        freerdp_input_send_synchronize_event(b->ctx->input, flags);
    pthread_mutex_unlock(&b->ctxLock);
}
void rdpbridge_send_cad(RDPBridge* b) {
    if (!b) return;
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input) {
        rdpInput* in = b->ctx->input;
        // Ctrl(0x1D) + Alt(0x38) + Delete(0x53, extended)
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_DOWN, 0x1D);
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_DOWN, 0x38);
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_DOWN | KBD_FLAGS_EXTENDED, 0x53);
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_RELEASE | KBD_FLAGS_EXTENDED, 0x53);
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_RELEASE, 0x38);
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_RELEASE, 0x1D);
    }
    pthread_mutex_unlock(&b->ctxLock);
}

// F-26 "Stay awake": inject a benign no-op keystroke so the remote session's idle
// timer (LASTINPUTINFO) resets and the screensaver/lock doesn't fire. F15 is used
// because it is a defined virtual key that essentially no application maps, so it
// reliably counts as input with no visible effect (the standard "caffeine" approach —
// preferred over a mouse jiggle, which can nudge a visible cursor). Scancode 0x66,
// non-extended, per RDP_SCANCODE_F15 in <freerdp/scancode.h>.
void rdpbridge_send_keepalive(RDPBridge* b) {
    if (!b) return;
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx && b->ctx->input) {
        rdpInput* in = b->ctx->input;
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_DOWN, 0x66);
        freerdp_input_send_keyboard_event(in, KBD_FLAGS_RELEASE, 0x66);
    }
    pthread_mutex_unlock(&b->ctxLock);
}

void rdpbridge_request_resize(RDPBridge* b, uint32_t width, uint32_t height,
                              uint32_t desktopScaleFactor) {
    if (!b || width < 2 || height < 2) return;
    // Stage the request; the RDP thread flushes it over the Display Control channel
    // (flush_pending_resize). If the channel isn't up yet, it's applied on connect.
    pthread_mutex_lock(&b->resizeLock);
    b->pendingW = width;
    b->pendingH = height;
    b->pendingSF = desktopScaleFactor;
    b->pendingResize = 1;
    pthread_mutex_unlock(&b->resizeLock);
    if (b->wakeEvent) SetEvent(b->wakeEvent);  // PERF-2: flush on next loop wake, now
}

void rdpbridge_set_clipboard_text(RDPBridge* b, const char* utf8Text) {
    if (!b || !utf8Text) return;
    if (strnlen(utf8Text, CLIP_MAX_UTF8_BYTES + 1) > CLIP_MAX_UTF8_BYTES) return;
    // Convert the local clipboard (UTF-8) to UTF-16LE for CF_UNICODETEXT and stash it;
    // served on demand when the server requests data (bridge_cliprdr_server_format_data_request).
    size_t wcharCount = 0; // wcslen (excludes terminator); buffer is zero-terminated
    WCHAR* wide = ConvertUtf8ToWCharAlloc(utf8Text, &wcharCount);
    if (!wide) return;

    pthread_mutex_lock(&b->clipLock);
    free(b->clipOutData);
    b->clipOutData = (BYTE*)wide;            // takes ownership
    b->clipOutLen = (wcharCount + 1) * sizeof(WCHAR); // include the NUL (CF_UNICODETEXT)
    // The local clipboard now holds text; drop any stale image/file offer
    // (single-item model — F-8: unstaging also closes the offered files' fds).
    free(b->clipOutImageData); b->clipOutImageData = NULL; b->clipOutImageLen = 0;
    clip_drop_staged_files_locked(b);
    b->pendingClipAnnounce = 1;              // flushed on the RDP thread
    pthread_mutex_unlock(&b->clipLock);
    if (b->wakeEvent) SetEvent(b->wakeEvent);  // PERF-2: flush on next loop wake, now
}

void rdpbridge_set_clipboard_image(RDPBridge* b, const uint8_t* dib, uint32_t len) {
    if (!b) return;
    pthread_mutex_lock(&b->clipLock);
    free(b->clipOutImageData);
    b->clipOutImageData = NULL;
    b->clipOutImageLen = 0;
    if (dib && len > 0 && len <= CLIP_MAX_IMAGE_BYTES) {
        b->clipOutImageData = (BYTE*)malloc(len);
        if (b->clipOutImageData) {
            memcpy(b->clipOutImageData, dib, len);
            b->clipOutImageLen = len;
        }
    }
    // The local clipboard now holds an image; drop any stale text/file offer
    // (single-item model — F-8: unstaging also closes the offered files' fds).
    free(b->clipOutData); b->clipOutData = NULL; b->clipOutLen = 0;
    clip_drop_staged_files_locked(b);
    b->pendingClipAnnounce = 1;              // flushed on the RDP thread
    pthread_mutex_unlock(&b->clipLock);
    if (b->wakeEvent) SetEvent(b->wakeEvent);  // PERF-2: flush on next loop wake, now
}

// F-8: stage a Mac→Windows file offer. Opens every file first (all-or-nothing, no
// partial staging), then swaps it in under clipLock and queues the format announce.
int rdpbridge_stage_file_offer(RDPBridge* b, const RDPBridgeFileOfferItem* items,
                               uint32_t count) {
    if (!b || !items || count == 0 || count > CLIP_MAX_OFFER_FILES) return 0;
    if (!b->cfg.fileClipboardEnabled) return 0;

    BridgeStagedFile* staged = (BridgeStagedFile*)calloc(count, sizeof(BridgeStagedFile));
    if (!staged) return 0;
    for (uint32_t i = 0; i < count; i++) staged[i].fd = -1;

    int failed = 0;
    for (uint32_t i = 0; i < count && !failed; i++) {
        const char* path = items[i].path;
        const char* name = items[i].name;
        if (!path || !*path || !name || !*name) { failed = 1; break; }
        // O_NOFOLLOW: a symlink at the leaf fails the open (Swift already rejected
        // symlinks via lstat; this makes it airtight against a swap between check and
        // open). O_NONBLOCK so a smuggled FIFO can't hang us; harmless on regular files.
        int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) { failed = 1; break; }
        struct stat st;
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
            close(fd);
            failed = 1;
            break;
        }
        staged[i].fd = fd;
        staged[i].size = (uint64_t)st.st_size;
        staged[i].name = strdup(name);
        if (!staged[i].name) { failed = 1; break; }
    }

    if (!failed) {
        pthread_mutex_lock(&b->clipLock);
        if (!b->serverFileClipOK) {
            // The server never negotiated streamed file-clip: refuse honestly instead
            // of staging an offer that could never be announced or pulled.
            failed = 1;
        } else {
            clip_drop_staged_files_locked(b);      // closes any previous offer's fds
            b->clipOutFiles = staged;
            b->clipOutFileCount = count;
            // Single-item model: the local clipboard now holds files.
            free(b->clipOutData); b->clipOutData = NULL; b->clipOutLen = 0;
            free(b->clipOutImageData); b->clipOutImageData = NULL; b->clipOutImageLen = 0;
            b->pendingClipAnnounce = 1;            // flushed on the RDP thread
        }
        pthread_mutex_unlock(&b->clipLock);
        if (!failed && b->wakeEvent) SetEvent(b->wakeEvent);  // PERF-2
    }

    if (failed) {
        for (uint32_t i = 0; i < count; i++) {
            free(staged[i].name);
            if (staged[i].fd >= 0) close(staged[i].fd);
        }
        free(staged);
        return 0;
    }
    return 1;
}

// F-8: explicitly drop a staged offer (fds closed) and re-announce without it.
void rdpbridge_clear_file_offer(RDPBridge* b) {
    if (!b) return;
    pthread_mutex_lock(&b->clipLock);
    int had = (b->clipOutFileCount > 0);
    clip_drop_staged_files_locked(b);
    if (had) b->pendingClipAnnounce = 1;
    pthread_mutex_unlock(&b->clipLock);
    if (had && b->wakeEvent) SetEvent(b->wakeEvent);  // PERF-2
}

// ---- #25: remote→Mac file pull (FILECONTENTS requests we issue) ----
// Called from Swift (any thread) while a Finder file promise is being fulfilled.
// Discipline: same as the input senders — ctxLock + the connected gate serialize the
// channel touch against RDP-thread processing/teardown; b->cliprdr is only mutated on
// the RDP thread under ctxLock (channel connect/disconnect events), so reading it here
// under the same lock is race-free. The channel write itself only queues the PDU
// (drained by the RDP thread), so no lock is held across network I/O.
static int bridge_send_file_contents_request(RDPBridge* b, uint32_t streamId,
                                             uint32_t listIndex, uint32_t dwFlags,
                                             uint64_t offset, uint32_t length) {
    if (!b || !b->cfg.fileClipboardEnabled) return 0;
    // Never issue FILECONTENTS PDUs the server didn't negotiate (mirrors the F-8 gate).
    pthread_mutex_lock(&b->clipLock);
    int negotiated = b->serverFileClipOK;
    pthread_mutex_unlock(&b->clipLock);
    if (!negotiated) return 0;

    int sent = 0;
    pthread_mutex_lock(&b->ctxLock);
    CliprdrClientContext* cliprdr = b->cliprdr;
    if (b->connected && cliprdr && cliprdr->ClientFileContentsRequest) {
        CLIPRDR_FILE_CONTENTS_REQUEST req;
        memset(&req, 0, sizeof(req));
        req.common.msgType = CB_FILECONTENTS_REQUEST;
        req.streamId = streamId;
        req.listIndex = listIndex;
        req.dwFlags = dwFlags;
        req.nPositionLow = (UINT32)(offset & 0xFFFFFFFFu);
        req.nPositionHigh = (UINT32)(offset >> 32);
        req.cbRequested = length;
        req.haveClipDataId = FALSE;   // we never lock the server clipboard (no FUSE);
                                      // a mid-pull server re-copy simply FAILs the pull
        sent = (cliprdr->ClientFileContentsRequest(cliprdr, &req) == CHANNEL_RC_OK);
    }
    pthread_mutex_unlock(&b->ctxLock);
    return sent;
}

int rdpbridge_request_file_size(RDPBridge* b, uint32_t streamId, uint32_t listIndex) {
    // MS-RDPECLIP: a SIZE request has position 0 and cbRequested 8 (the reply is the
    // 8-byte little-endian file size).
    return bridge_send_file_contents_request(b, streamId, listIndex,
                                             FILECONTENTS_SIZE, 0, 8);
}

int rdpbridge_request_file_range(RDPBridge* b, uint32_t streamId, uint32_t listIndex,
                                 uint64_t offset, uint32_t length) {
    // SEC-3: refuse a chunk larger than the response ceiling up front (Swift asks for
    // ≤ 4 MiB; anything past 8 MiB could never be delivered anyway).
    if (length == 0 || length > CLIP_MAX_PULL_RESPONSE_BYTES) return 0;
    return bridge_send_file_contents_request(b, streamId, listIndex,
                                             FILECONTENTS_RANGE, offset, length);
}

void rdpbridge_get_stats(RDPBridge* b, uint64_t* compressedBytes, uint64_t* frameCount,
                         uint32_t* rttMs, uint32_t* bwKbps) {
    if (compressedBytes) *compressedBytes = 0;
    if (frameCount) *frameCount = 0;
    if (rttMs) *rttMs = 0;
    if (bwKbps) *bwKbps = 0;
    if (!b) return;
    // CONC-5: read metrics/autodetect (RDP-thread-owned ctx sub-objects) under ctxLock +
    // the connected gate so they can't be torn down mid-read (UAF window vs disconnect).
    // frameCount is an atomic counter, safe to read outside the gate; the sampler already
    // tolerates zeros while disconnected.
    if (frameCount) *frameCount = atomic_load_explicit(&b->frameCounter, memory_order_relaxed);
    pthread_mutex_lock(&b->ctxLock);
    if (b->connected && b->ctx) {
        if (compressedBytes && b->ctx->metrics) *compressedBytes = b->ctx->metrics->TotalCompressedBytes;
        // Server-reported network characteristics (populated only if the server runs
        // continuous autodetect; 0 means "unknown" and the UI hides that metric).
        rdpAutoDetect* ad = b->ctx->autodetect;
        if (ad) {
            if (rttMs)  *rttMs  = ad->netCharAverageRTT;
            if (bwKbps) *bwKbps = ad->netCharBandwidth;
        }
    }
    pthread_mutex_unlock(&b->ctxLock);
}

const char* rdpbridge_freerdp_version(void) { return freerdp_get_version_string(); }

// PERF-8: freerdp_get_build_config() is the library's CMake option list rendered as
// "WITH_X=ON WITH_Y=OFF ..." — the only runtime signal of how the dylib was built.
int rdpbridge_h264_hw_decode_available(void) {
    const char* cfg = freerdp_get_build_config();
    return (cfg && strstr(cfg, "WITH_VIDEOTOOLBOX=ON")) ? 1 : 0;
}
