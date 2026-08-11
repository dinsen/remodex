// FILE: SidebarPinIcon.swift
// Purpose: Single pin glyph reused by the Pinned section header and by every
//          pinned thread row so asset, size and weight stay in sync across
//          surfaces. Row variant uses the shared sidebar metadata tint.
// Layer: View Component
// Exports: SidebarPinIcon
// Depends on: SwiftUI, RemodexIcon, AppFont, SidebarForegroundStyle

import SwiftUI

struct SidebarPinIcon: View {
    enum Style {
        // Pinned section header glyph: outline pin, prominent.
        case header
        // Inline badge prepended to a pinned thread row's title.
        case rowBadge
    }

    let style: Style

    @ViewBuilder
    var body: some View {
        switch style {
        case .header:
            RemodexIcon.image(systemName: "pin", size: 18, weight: .medium)
                .foregroundStyle(style.foregroundStyle)
        case .rowBadge:
            Image(systemName: "pin.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(style.foregroundStyle)
                .accessibilityHidden(true)
        }
    }
}

private extension SidebarPinIcon.Style {
    var foregroundStyle: AnyShapeStyle {
        switch self {
        case .header:
            AnyShapeStyle(HierarchicalShapeStyle.primary)
        case .rowBadge:
            AnyShapeStyle(SidebarForegroundStyle.meta)
        }
    }
}

#if DEBUG
#Preview("SidebarPinIcon") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
            SidebarPinIcon(style: .header)
            Text("Pinned").font(AppFont.body(weight: .medium))
        }
        HStack(spacing: 6) {
            SidebarPinIcon(style: .rowBadge)
            Text("Investigate flaky tests")
        }
    }
    .padding()
}
#endif
