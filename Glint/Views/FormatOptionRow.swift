import SwiftUI

/// One choice in a format panel row. `isAvailable` false greys it out, for what the lens can't record.
struct FormatOption<Value: Hashable> {
    let title: String
    var spoken: String?
    var isAvailable = true
    let value: Value

    init(title: String, spoken: String? = nil, isAvailable: Bool = true, value: Value) {
        self.title = title
        self.spoken = spoken
        self.isAvailable = isAvailable
        self.value = value
    }
}

/// A labelled row of choices in a format panel; the selected one is amber.
struct FormatOptionRow<Value: Hashable>: View {
    let title: String
    let groupLabel: String
    let options: [FormatOption<Value>]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { i in
                    let option = options[i]
                    let selected = option.value == selection
                    Button { onSelect(option.value) } label: {
                        Text(option.title)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .background(selected ? Color.amber : Color.white.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.isAvailable)
                    .opacity(option.isAvailable ? 1 : 0.35)
                    .accessibilityLabel(option.spoken ?? option.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(groupLabel)
        }
    }
}
