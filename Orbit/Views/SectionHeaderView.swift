import SwiftUI

public struct SectionHeaderView: View {
    public let title: String
    
    public init(title: String) {
        self.title = title
    }
    
    public var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .regular))
            .foregroundColor(Color.white.opacity(0.3))
            .tracking(0.5)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
