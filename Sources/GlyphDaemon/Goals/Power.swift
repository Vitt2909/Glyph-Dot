import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
import IOKit.ps
#endif

/// Mantém o Mac acordado **só enquanto** há tarefa noturna, **só na tomada**,
/// e só se o usuário ligou `turno_noturno.manter_acordado` (opt-in).
public final class NightPower: @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(IOKit)
    private var assertion: IOPMAssertionID = 0
    #endif
    private var held = false

    public init() {}

    public static var onACPower: Bool {
        #if canImport(IOKit)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMACPowerKey
        #else
        return false
        #endif
    }

    public func hold(reason: String = "Glyph: turno noturno") -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !held, Self.onACPower else { return held }
        #if canImport(IOKit)
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
        held = r == kIOReturnSuccess
        #endif
        return held
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard held else { return }
        #if canImport(IOKit)
        IOPMAssertionRelease(assertion)
        #endif
        held = false
    }
}
