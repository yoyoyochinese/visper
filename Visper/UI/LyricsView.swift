import SwiftUI

/// 歌詞風のライブ表示（D15）。値だけを受け取るので、置き場所を選ばない。
struct LyricsView: View {
    let lines: [String]
    let tentative: String

    @State private var following = true
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        // ponytail: 全行を VStack に並べる。2時間分で重くなったら LazyVStack にする。
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    let isCurrent = index == lines.count - 1
                    Text(line)
                        .font(isCurrent ? .title2.bold() : .body)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .accessibilityIdentifier("lyricsLine")
                }
                if !tentative.isEmpty {
                    Text(tentative)
                        .font(.title2.bold())
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("lyricsTentative")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .scrollPosition($position)
        .accessibilityIdentifier("lyricsScroll")
        // 手動スクロールの間は追従を止め、指を離した位置が一番下なら再開する。
        // 自動スクロールは .animating なのでここには来ない。
        .onScrollPhaseChange { old, phase, context in
            switch phase {
            case .tracking, .interacting, .decelerating:
                following = false
            case .idle where old != .animating:
                let geometry = context.geometry
                following = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 20
            default:
                break
            }
        }
        .onChange(of: lines.count) { follow() }
        .onChange(of: tentative) { follow() }
        .overlay(alignment: .bottom) {
            if !following {
                Button("最新へ", systemImage: "arrow.down") {
                    following = true
                    follow()
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 10)
                .accessibilityIdentifier("jumpToLatest")
            }
        }
    }

    private func follow() {
        guard following else { return }
        withAnimation { position.scrollTo(edge: .bottom) }
    }
}
