import Foundation

/// What the header of an expandable row without a master switch (`GGMenuRowKind.expandableList`)
/// sums up: how many of its visible children are on. Foundation only: host-tested.
public struct GGMenuGroupCount: Equatable {
    public let selected: Int
    public let total: Int

    public init(selected: Int, total: Int) {
        self.selected = selected
        self.total = total
    }

    /// The values of the visible children, in any order.
    public init(values: [Bool]) {
        self.init(selected: values.filter { $0 }.count, total: values.count)
    }

    /// The text on the right of the header: nil while no child is on («пусто, если ничего не
    /// выбрано»), otherwise the feature's own wording («скрыто: 2 из 4»).
    public func summary(_ text: (GGMenuGroupCount) -> String) -> String? {
        if self.selected == 0 {
            return nil
        }
        return text(self)
    }
}
