import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    let geometry: NotchGeometry

    @State private var bridge = OverlayBridge()

    var body: some View {
        OverlayShellView(
            bridge: bridge,
            geometry: geometry,
            payload: {
                AnyView(
                    OverlayPayloadSlot(
                        viewModel: viewModel,
                        geometry: geometry
                    ) { _ in }
                )
            }
        )
        .onAppear {
            bridge.activeStatus = viewModel.activeSession()?.status ?? .waitingForInput
        }
        .onReceive(viewModel.$sessions) { _ in
            bridge.activeStatus = viewModel.activeSession()?.status ?? .waitingForInput
        }
    }
}
