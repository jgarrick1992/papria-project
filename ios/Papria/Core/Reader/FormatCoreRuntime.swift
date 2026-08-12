import Foundation
import papria_format_coreFFI

/// Direct runtime probe for the mandatory Rust/UniFFI format core.
///
/// The app target links PapriaFormatCore on every build. Referencing its
/// contract symbol directly makes a missing XCFramework a build/link failure
/// instead of silently selecting a Swift parser fallback.
enum FormatCoreRuntime {
    static func linkedContractVersion() -> UInt32? {
        ffi_papria_format_core_uniffi_contract_version()
    }
}
