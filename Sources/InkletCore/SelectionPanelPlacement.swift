import Foundation

public struct SelectionPanelSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct SelectionScreenFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

public struct SelectionPanelRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ point: SelectionPoint) -> Bool {
        point.x >= x
            && point.x <= x + width
            && point.y >= y
            && point.y <= y + height
    }
}

public enum SelectionPanelPlacement {
    public static func origin(
        forPanelSize panelSize: SelectionPanelSize,
        near anchor: SelectionPoint,
        in visibleFrame: SelectionScreenFrame,
        gap: Double = 18,
        margin: Double = 8
    ) -> SelectionPoint {
        let rightX = anchor.x + gap
        let leftX = anchor.x - panelSize.width - gap
        let preferredX = rightX + panelSize.width <= visibleFrame.maxX - margin ? rightX : leftX

        let aboveY = anchor.y + gap
        let belowY = anchor.y - panelSize.height - gap
        let preferredY = belowY >= visibleFrame.minY + margin ? belowY : aboveY

        return SelectionPoint(
            x: min(max(preferredX, visibleFrame.minX + margin), visibleFrame.maxX - panelSize.width - margin),
            y: min(max(preferredY, visibleFrame.minY + margin), visibleFrame.maxY - panelSize.height - margin)
        )
    }
}

public enum SelectionPanelSizing {
    public static func translationResultSize(
        textLength: Int,
        fittingSize: SelectionPanelSize,
        rememberedSize: SelectionPanelSize? = nil,
        rememberedMinimumSize: SelectionPanelSize? = nil,
        rememberedMaximumSize: SelectionPanelSize? = nil,
        minimumSize: SelectionPanelSize = SelectionPanelSize(width: 320, height: 220),
        mediumSize: SelectionPanelSize = SelectionPanelSize(width: 440, height: 340),
        maximumSize: SelectionPanelSize = SelectionPanelSize(width: 520, height: 420)
    ) -> SelectionPanelSize {
        if let rememberedSize {
            return clamped(
                rememberedSize,
                minimumSize: rememberedMinimumSize ?? minimumSize,
                maximumSize: rememberedMaximumSize ?? maximumSize
            )
        }

        let targetSize: SelectionPanelSize
        if textLength >= 900 {
            targetSize = maximumSize
        } else if textLength >= 240 {
            targetSize = mediumSize
        } else {
            targetSize = minimumSize
        }

        return clamped(
            SelectionPanelSize(
                width: max(fittingSize.width, targetSize.width),
                height: max(fittingSize.height, targetSize.height)
            ),
            minimumSize: targetSize,
            maximumSize: maximumSize
        )
    }

    private static func clamped(
        _ size: SelectionPanelSize,
        minimumSize: SelectionPanelSize,
        maximumSize: SelectionPanelSize
    ) -> SelectionPanelSize {
        SelectionPanelSize(
            width: min(max(size.width, minimumSize.width), maximumSize.width),
            height: min(max(size.height, minimumSize.height), maximumSize.height)
        )
    }
}

public struct SelectionPanelDragRegions: Equatable, Sendable {
    public let panelSize: SelectionPanelSize
    public let exclusionRects: [SelectionPanelRect]
    public let resizeEdgeWidth: Double

    public init(
        panelSize: SelectionPanelSize,
        exclusionRects: [SelectionPanelRect],
        resizeEdgeWidth: Double = 8
    ) {
        self.panelSize = panelSize
        self.exclusionRects = exclusionRects
        self.resizeEdgeWidth = resizeEdgeWidth
    }

    public static func translationResultRegions(panelSize: SelectionPanelSize) -> SelectionPanelDragRegions {
        let padding = 10.0
        let toolbarHeight = 48.0
        let buttonHeight = 34.0
        let buttonY = 7.0
        let audioClusterWidth = min(180.0, max(120.0, panelSize.width * 0.42))

        return SelectionPanelDragRegions(
            panelSize: panelSize,
            exclusionRects: [
                SelectionPanelRect(
                    x: padding,
                    y: toolbarHeight,
                    width: max(0, panelSize.width - padding * 2),
                    height: max(0, panelSize.height - toolbarHeight - padding)
                ),
                SelectionPanelRect(x: padding, y: buttonY, width: 46, height: buttonHeight),
                SelectionPanelRect(
                    x: max(padding, panelSize.width - audioClusterWidth - padding),
                    y: buttonY,
                    width: audioClusterWidth,
                    height: buttonHeight
                )
            ]
        )
    }

    public func isBackgroundDragPoint(_ point: SelectionPoint) -> Bool {
        guard point.x > resizeEdgeWidth,
              point.y > resizeEdgeWidth,
              point.x < panelSize.width - resizeEdgeWidth,
              point.y < panelSize.height - resizeEdgeWidth
        else {
            return false
        }

        return !exclusionRects.contains { $0.contains(point) }
    }
}
