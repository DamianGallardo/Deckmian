//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let onClick: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .symbolVariant(.fill)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? .white : (isHovering ? .white.opacity(0.85) : .gray))
                .scaleEffect(selected ? 1.05 : 1)
                // Flexible width so all tabs fit in the space beside the notch
                .frame(minWidth: 22, maxWidth: 36, minHeight: 26, maxHeight: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
