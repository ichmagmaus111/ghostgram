import Foundation
import GGCore

// The studio's composed labels. The per-item names (filters, parameters, anchors…) are generated
// into GGMaskStudioNamesGenerated.swift.

extension GGMaskStudioNames {
    static func layerTitle(_ effect: GGMaskEffect) -> String {
        if effect.type == .filter, let id = effect.filterId, GGFilterCatalog.descriptor(id) != nil {
            return GGMaskStudioNames.filterTitle(id)
        }
        return GGMaskStudioNames.effectType(effect.type)
    }

    static func layerSubtitle(_ effect: GGMaskEffect) -> String {
        var parts: [String] = []
        if effect.type == .filter, let id = effect.filterId, let descriptor = GGFilterCatalog.descriptor(id) {
            parts.append(GGMaskStudioNames.category(descriptor.category))
            if descriptor.param("anchor") != nil, let anchor = effect.effectiveAnchor {
                parts.append(GGMaskStudioNames.anchor(anchor))
            }
        } else if let anchor = effect.anchor {
            parts.append(GGMaskStudioNames.anchor(anchor))
        }
        if !effect.isEnabled {
            parts.append(GGStrings.CameraMasks.Studio.layerOff)
        }
        return parts.joined(separator: " · ")
    }

    static func filterSubtitle(_ descriptor: GGFilterDescriptor) -> String {
        var text = GGStrings.CameraMasks.Studio.layerCost(units: "\(descriptor.cost)")
        if descriptor.isHeavy {
            text += " · " + GGStrings.CameraMasks.Studio.heavy
        }
        return text + GGMaskStudioNames.needsSuffix(descriptor.needs)
    }

    /// « · needs a face» and the like; empty when the layer needs nothing from Vision.
    static func needsSuffix(_ needs: GGVisionNeeds) -> String {
        if needs.contains(.segmentation) {
            return " · " + GGStrings.CameraMasks.Studio.needsSegmentation
        }
        if needs.contains(.landmarks) {
            return " · " + GGStrings.CameraMasks.Studio.needsLandmarks
        }
        if needs.contains(.face) {
            return " · " + GGStrings.CameraMasks.Studio.needsFace
        }
        return ""
    }

    static func violation(_ violation: GGMaskBudget.Violation) -> String {
        switch violation {
        case let .tooManyEffects(limit):
            return GGStrings.CameraMasks.Studio.Violation.tooManyEffects(count: limit)
        case .tooManyHeavy:
            return GGStrings.CameraMasks.Studio.Violation.tooManyHeavy
        case .tooManySegmentation:
            return GGStrings.CameraMasks.Studio.Violation.tooManySegmentation
        case .tooManyFaceWarps:
            return GGStrings.CameraMasks.Studio.Violation.tooManyFaceWarps
        case .tooManyAnimated:
            return GGStrings.CameraMasks.Studio.Violation.tooManyAnimated
        case .overBudget:
            return GGStrings.CameraMasks.Studio.Violation.overBudget
        }
    }
}
