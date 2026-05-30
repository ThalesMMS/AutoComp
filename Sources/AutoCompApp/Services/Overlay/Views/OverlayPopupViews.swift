import AutoCompCore
import SwiftUI

// MARK: - SwiftUI popup views

struct SimpleCaretPopupView: View {
    let text: String
    let acceptKeycapHint: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary.opacity(0.82))
            Text(acceptKeycapHint)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.13))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct MultiSuggestionPopupView: View {
    let alternatives: [SuggestionAlternative]
    let selectedIndex: Int
    let acceptKeycapHint: String
    let previousKeycapHint: String
    let nextKeycapHint: String

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(alternatives.prefix(3).enumerated()), id: \.offset) { index, alternative in
                HStack(spacing: 8) {
                    Text(SimpleCaretPopupLayout.normalized(alternative.visibleText))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(index == selectedIndex ? .primary : .secondary)

                    Spacer(minLength: 8)

                    if index == selectedIndex {
                        HStack(spacing: 4) {
                            Text(previousKeycapHint)
                            Text(nextKeycapHint)
                            Text(acceptKeycapHint)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.secondary.opacity(0.13))
                        )
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(index == selectedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
