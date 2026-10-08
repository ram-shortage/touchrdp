// swift-tools-version:6.0
import PackageDescription
import Foundation

// TouchRDP — native macOS RDP client with Touch ID credential release.
// Build the runnable .app with: ./Tools/build-app.sh
//
// Layering (enforced by target deps):
//   CRDPBridge      — thin C shim over libfreerdp-client3 (clean C API to Swift)
//   TouchRDPCore    — pure Swift: models, protocols, CredentialVault, ConnectionStore, KeyboardMap
//   TouchRDPEngine  — Swift wrapper turning CRDPBridge into an RDPSession (conforms to Core protocol)
//   TouchRDP        — AppKit/SwiftUI executable (app shell)
//
// NOTE (AS-2): links Homebrew FreeRDP at /opt/homebrew by default. PERF-8 / M3: when
// Tools/build-freerdp.sh has installed the pinned from-source FreeRDP (built with
// VideoToolbox H.264 decoding, which the Homebrew bottle lacks) under Vendor/freerdp,
// that prefix is linked instead. TOUCHRDP_FREERDP_PREFIX=/path overrides both.

let brewPrefix = "/opt/homebrew"
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendoredFreeRDP = packageDir + "/Vendor/freerdp"
let freerdpPrefix: String = {
    if let p = ProcessInfo.processInfo.environment["TOUCHRDP_FREERDP_PREFIX"], !p.isEmpty {
        return p
    }
    if FileManager.default.fileExists(atPath: vendoredFreeRDP + "/lib/libfreerdp-client3.dylib") {
        return vendoredFreeRDP
    }
    return brewPrefix
}()

let package = Package(
    name: "TouchRDP",
    platforms: [.macOS(.v14)],
    targets: [
        // C bridge over FreeRDP. Public header exposes only our clean API.
        .target(
            name: "CRDPBridge",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-I\(freerdpPrefix)/include/freerdp3",
                    "-I\(freerdpPrefix)/include/winpr3",
                    "-I\(brewPrefix)/include",   // OpenSSL headers
                    "-Wno-deprecated-declarations",
                    // Keep the build machine's directory out of __FILE__ strings.
                    "-fmacro-prefix-map=\(packageDir)/=",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(freerdpPrefix)/lib",
                    "-L\(brewPrefix)/lib",       // libcrypto (+ Homebrew FreeRDP fallback)
                    "-lfreerdp-client3", "-lfreerdp3", "-lwinpr3", "-lcrypto",
                ]),
            ]
        ),

        // Pure-Swift core: no FreeRDP, no UI. Independently buildable + testable.
        .target(
            name: "TouchRDPCore",
            linkerSettings: [
                .linkedFramework("IOSurface"), // RemoteFrame (PERF-5 zero-copy frames)
            ]
        ),

        // Swift engine: bridges CRDPBridge -> RDPSession protocol from Core.
        .target(
            name: "TouchRDPEngine",
            dependencies: ["CRDPBridge", "TouchRDPCore"],
            linkerSettings: [
                .linkedFramework("IOSurface"), // FrameSurfacePool
            ]
        ),

        // The app executable (AppKit + SwiftUI).
        .executableTarget(
            name: "TouchRDP",
            dependencies: ["TouchRDPCore", "TouchRDPEngine"],
            exclude: ["Icon.png"], // consumed by Tools/build-app.sh, not an SPM resource
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
                .linkedFramework("Carbon"), // keyboard scancode mapping
                .linkedFramework("IOSurface"), // frame surfaces as layer contents
            ]
        ),

        // Unit tests for the security-critical + pure-logic core.
        .testTarget(
            name: "TouchRDPCoreTests",
            // TouchRDPEngine is included so SessionController's UI-facing state machine
            // (cursor/stats reset on disconnect) is covered by a test double session.
            dependencies: ["TouchRDPCore", "TouchRDPEngine", "CRDPBridge"]
        ),

        // Headless validation harness (plain asserts; runs under Command Line Tools,
        // unlike the XCTest target which needs full Xcode). `swift run ValidateCore`.
        .executableTarget(
            name: "ValidateCore",
            dependencies: ["TouchRDPCore"]
        ),

        // Live end-to-end validation: drives a real RDP connection via CRDPBridge and
        // exercises the clipboard channel. `swift run ValidateLive <host> <port> ...`.
        .executableTarget(
            name: "ValidateLive",
            dependencies: ["CRDPBridge"],
            linkerSettings: [ .linkedFramework("Security") ]
        ),
    ],
    swiftLanguageModes: [.v5] // AS-7: v5 mode to avoid Swift6 strict-concurrency churn derailing the build; revisit later.
)
