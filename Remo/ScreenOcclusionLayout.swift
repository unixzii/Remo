//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import SwiftUI

/// Computes per-control edge insets from exact hardware/system occlusion regions and container
/// corner insets, so an asymmetric cutout (such as iPhone Duo's corner camera) only pushes
/// controls that actually intersect it instead of insetting an entire edge.
@available(iOS 27.1, *)
struct ScreenOcclusionLayout {
    struct Occlusion {
        /// Reserved rect in the container's coordinate space, already including system margins.
        let frame: CGRect
        /// Interactive margins already included inside `frame`.
        let margins: EdgeInsets
    }

    let size: CGSize
    let occlusions: [Occlusion]

    init(proxy: GeometryProxy) {
        self.size = proxy.size
        self.occlusions = proxy.reservedRegions(kind: .occlusion).map {
            Occlusion(frame: $0.frame, margins: $0.margins)
        }
    }

    /// Trailing inset for a control centered vertically in the space above `bottomInset`.
    func trailingInset(
        forCenteredHeight height: CGFloat,
        width controlWidth: CGFloat,
        bottomInset: CGFloat,
        baseMargin: CGFloat = 16,
        minimumCutoutGap: CGFloat = 12
    ) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return baseMargin }

        let availableHeight = max(0, size.height - bottomInset)
        let minY = max(0, (availableHeight - height) / 2)
        let maxY = minY + height

        var trailing = baseMargin

        let sortedOcclusions =
            occlusions
            .filter { !$0.frame.isEmpty }
            .sorted { $0.frame.maxX > $1.frame.maxX }

        for occlusion in sortedOcclusions {
            let avoid = expandedRect(for: occlusion, minimumGap: minimumCutoutGap)
            guard avoid.maxY > minY, avoid.minY < maxY else { continue }
            guard avoid.midX > size.width / 2 else { continue }
            if avoid.maxX > size.width - trailing - controlWidth {
                trailing = max(trailing, size.width - avoid.minX)
            }
        }

        return trailing
    }

    private func expandedRect(for occlusion: Occlusion, minimumGap: CGFloat) -> CGRect {
        let frame = occlusion.frame
        let extraLeading = max(0, minimumGap - occlusion.margins.leading)
        let extraTrailing = max(0, minimumGap - occlusion.margins.trailing)
        let extraTop = max(0, minimumGap - occlusion.margins.top)
        let extraBottom = max(0, minimumGap - occlusion.margins.bottom)
        return CGRect(
            x: frame.minX - extraLeading,
            y: frame.minY - extraTop,
            width: frame.width + extraLeading + extraTrailing,
            height: frame.height + extraTop + extraBottom)
    }
}
