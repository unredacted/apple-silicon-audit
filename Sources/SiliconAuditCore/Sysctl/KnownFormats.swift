import Foundation

/// Declared formats for keys the engine reads by name, used only when the kernel refuses
/// CTL_SYSCTL_OIDFMT. The iOS sandbox does exactly that (M0 spike, iPhone18,2 / 26.6.2):
/// `sysctlbyname` works, the meta nodes do not. Values decoded this way carry
/// `OIDFormat.Source.inventory` so exports can say the type came from us, not the kernel.
/// Phase 3 moves this table into `known-keys.json`.
public enum KnownFormats {
    public static func format(for name: String) -> OIDFormat? {
        if let f = DataStore.shared.knownKeys.format(for: name) { return f }
        if let f = table[name] { return f }
        // Every hw.optional leaf XNU registers is a SYSCTL_INT except `caps` (listed above).
        if name.hasPrefix("hw.optional.") { return inventory(.int) }
        return nil
    }

    static func inventory(_ f: OIDFormat) -> OIDFormat {
        OIDFormat(kind: f.kind, formatString: f.formatString, source: .inventory)
    }

    static let table: [String: OIDFormat] = [
        "hw.product": inventory(.string), "hw.machine": inventory(.string), "hw.model": inventory(.string),
        "hw.target": inventory(.string), "hw.targettype": inventory(.string),
        "hw.cputype": inventory(.int), "hw.cpusubtype": inventory(.int),
        "hw.cpufamily": inventory(.int), "hw.cpusubfamily": inventory(.int),
        "hw.ncpu": inventory(.int), "hw.nperflevels": inventory(.int),
        "hw.memsize": inventory(.quad), "hw.pagesize": inventory(.quad),
        "hw.features.allows_security_research": inventory(.int), "hw.engineering_sample": inventory(.int),
        "kern.version": inventory(.string), "kern.osversion": inventory(.string),
        "kern.osproductversion": inventory(.string), "kern.osreleasetype": inventory(.string),
        "kern.hv_support": inventory(.int), "kern.hv_vmm_present": inventory(.int),
        "sysctl.proc_translated": inventory(.int),
        "hw.optional.arm.caps": inventory(.quad),
        "vm.mte.tagged": inventory(.int), "vm.mte.cell.active": inventory(.int),
        "vm.mte.tag_storage.activations": inventory(.quad),
    ]
}

extension ProbeOutcome {
    /// If the kernel supplied no format, re-decode the same bytes with the inventory's
    /// declared format for this key. Bytes are never altered; only their interpretation.
    public func withInventoryFormat(for name: String) -> ProbeOutcome {
        guard case .value(let v) = self, v.format == nil, let known = KnownFormats.format(for: name) else { return self }
        return .value(SysctlValue(format: known, bytes: v.rawBytes))
    }
}
