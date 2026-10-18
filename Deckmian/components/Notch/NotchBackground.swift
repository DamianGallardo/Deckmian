//
//  NotchBackground.swift
//  Deckmian
//
//  Background of the notch shape: solid black by default, translucent glass in Glass mode.
//

import Defaults
import SwiftUI

struct NotchBackground: View {
    let shape: NotchShape
    let isOpen: Bool

    @Default(.glassMode) private var glassMode
    @Default(.glassModeTint) private var glassModeTint

    /// The closed notch stays solid black so it keeps blending with the hardware notch.
    /// When open in Glass mode, the black layer fades down to the tint opacity, crossfading
    /// with the glass underneath as the notch animates open/closed.
    private var showsGlass: Bool { glassMode && isOpen }

    private var blackOpacity: Double {
        showsGlass ? min(max(glassModeTint, 0), 0.8) : 1
    }

    var body: some View {
        if glassMode {
            ZStack {
                glassLayer
                    .opacity(showsGlass ? 1 : 0)
                shape
                    .fill(.black)
                    .opacity(blackOpacity)
            }
        } else {
            Color.black
        }
    }

    @ViewBuilder
    private var glassLayer: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
        } else {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(shape)
        }
    }
}
