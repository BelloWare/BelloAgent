// The alias box frozen from v0.1.119's ModelRoutingMap.
import SwiftUI
@testable import PiApp

struct ReportRoutingAliasReference: View {
    let alias: String
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 18))
            Text(alias).font(PiFont.caption.weight(.medium)).lineLimit(3).textSelection(.enabled)
        }.padding(9).frame(width: 116).background(Color.piFill, in: RoundedRectangle(cornerRadius: 10))
    }
}
