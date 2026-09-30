import XCTest
import SwiftUI
import AppKit
@testable import PiApp

/// The app's own switch, checkbox, spinner, progress bar and date field take
/// the room the stock controls they replaced took, at every control size
/// used, so no row, pill or sheet changes its height or width. A switch whose
/// label is hidden (`Toggle("", …)`) takes the stock switch's room exactly.
final class PiControlSizeTests: XCTestCase {
    @MainActor private func size<V: View>(_ view: V) -> CGSize {
        let hosted = NSHostingView(rootView: view.fixedSize())
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize
    }

    @MainActor func testTheSwitchTakesTheStockSwitchsRoomAtEachSize() {
        for controlSize in [ControlSize.mini, .small, .regular] {
            for on in [false, true] {
                let stock = size(Toggle("", isOn: .constant(on)).toggleStyle(.switch).labelsHidden().controlSize(controlSize))
                let pi = size(Toggle("", isOn: .constant(on)).toggleStyle(.piSwitch).labelsHidden().controlSize(controlSize))
                XCTAssertEqual(pi, stock, "\(controlSize) switch, \(on ? "on" : "off")")
                let stockLabelled = size(Toggle("Wrap", isOn: .constant(on)).toggleStyle(.switch).controlSize(controlSize).font(PiFont.micro))
                let piLabelled = size(Toggle("Wrap", isOn: .constant(on)).toggleStyle(.piSwitch).controlSize(controlSize).font(PiFont.micro))
                XCTAssertEqual(piLabelled.height, stockLabelled.height, "\(controlSize) labelled switch height")
                XCTAssertEqual(piLabelled.width, stockLabelled.width, accuracy: 2, "\(controlSize) labelled switch width")
            }
        }
    }

    @MainActor func testTheCheckboxTakesTheStockCheckboxsRoom() {
        for on in [false, true] {
            let stock = size(Toggle("Final model not reported", isOn: .constant(on)).toggleStyle(.checkbox).font(PiFont.caption))
            let pi = size(Toggle("Final model not reported", isOn: .constant(on)).toggleStyle(.piCheckbox).font(PiFont.caption))
            XCTAssertEqual(pi.height, stock.height, "checkbox height, \(on ? "on" : "off")")
            XCTAssertEqual(pi.width, stock.width, accuracy: 2, "checkbox width, \(on ? "on" : "off")")
        }
    }

    @MainActor func testTheSpinnerAndTheBarTakeTheStockRoom() {
        for controlSize in [ControlSize.mini, .small, .regular] {
            XCTAssertEqual(size(PiSpinner(controlSize: controlSize)), size(ProgressView().controlSize(controlSize)), "\(controlSize) spinner")
        }
        let stock = size(ProgressView(value: 3, total: 10).frame(width: 300))
        XCTAssertEqual(size(PiProgressBar(value: 3, total: 10).frame(width: 300)), stock, "the bar")
    }

    @MainActor func testTheDateFieldTakesTheStockFieldsRoom() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let stock = size(DatePicker("", selection: .constant(date), displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.field).labelsHidden().controlSize(.small).font(PiFont.caption))
        let pi = size(PiDateField(date: .constant(date)))
        XCTAssertEqual(pi.height, stock.height, accuracy: 1, "date field height")
        XCTAssertEqual(pi.width, stock.width, accuracy: 12, "date field width")
    }
}
