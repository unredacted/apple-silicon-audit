import Foundation

/// Declared formats for keys the engine reads by name, used only when the kernel refuses
/// CTL_SYSCTL_OIDFMT. The iOS sandbox does exactly that (M0 spike, iPhone18,2 / 26.6.2):
/// `sysctlbyname` works, the meta nodes do not. Values decoded this way carry
/// `OIDFormat.Source.inventory` so exports can say the type came from us, not the kernel.
/// Phase 3 moves this table into `known-keys.json`.
public enum KnownFormats {
    /// Declared format for `name` from the given inventory, falling back to the built-in table
    /// (which exists so environment detection works even if the bundle is unreadable).
    public static func format(for name: String, inventory: KnownKeyInventory) -> OIDFormat? {
        if let f = inventory.format(for: name) { return f }
        if let f = table[name] { return f }
        // Every hw.optional leaf XNU registers is a SYSCTL_INT except `caps` (listed above).
        if name.hasPrefix("hw.optional.") { return inv(.int) }
        return nil
    }

    static func inv(_ f: OIDFormat) -> OIDFormat {
        OIDFormat(kind: f.kind, formatString: f.formatString, source: .inventory)
    }

    static let table: [String: OIDFormat] = [
        "hw.product": inv(.string), "hw.machine": inv(.string), "hw.model": inv(.string),
        "hw.target": inv(.string), "hw.targettype": inv(.string),
        "hw.cputype": inv(.int), "hw.cpusubtype": inv(.int),
        "hw.cpufamily": inv(.int), "hw.cpusubfamily": inv(.int),
        "hw.ncpu": inv(.int), "hw.nperflevels": inv(.int),
        "hw.memsize": inv(.quad), "hw.pagesize": inv(.quad),
        "hw.features.allows_security_research": inv(.int), "hw.engineering_sample": inv(.int),
        "kern.version": inv(.string), "kern.osversion": inv(.string),
        "kern.osproductversion": inv(.string), "kern.osreleasetype": inv(.string),
        "kern.hv_support": inv(.int), "kern.hv_vmm_present": inv(.int),
        "sysctl.proc_translated": inv(.int),
        "hw.optional.arm.caps": inv(.quad),
        "vm.mte.tagged": inv(.int), "vm.mte.cell.active": inv(.int),
        "vm.mte.tag_storage.activations": inv(.quad),
    ]
}

extension ProbeOutcome {
    /// If the kernel supplied no format, re-decode the same bytes with the inventory's
    /// declared format for this key. Bytes are never altered; only their interpretation.
    public func withInventoryFormat(for name: String, inventory: KnownKeyInventory) -> ProbeOutcome {
        guard case .value(let v) = self, v.format == nil, let known = KnownFormats.format(for: name, inventory: inventory) else { return self }
        return .value(SysctlValue(format: known, bytes: v.rawBytes))
    }
}
