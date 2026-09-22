import SwiftUI

struct AdjustmentPanel: View {
    @Binding var adjustments: MediaAdjustments
    @Binding var selectedParameterID: String
    let onChange: () -> Void
    let onReset: () -> Void

    private var selected: AdjustmentParameter {
        AdjustmentParameter.all.first { $0.id == selectedParameterID }
            ?? AdjustmentParameter.all[0]
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(selected.title)
                    .font(.subheadline.bold())

                Spacer()

                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("还原") {
                    onReset()
                }
                .font(.caption)
            }
            .padding(.horizontal)

            Slider(
                value: Binding(
                    get: { adjustments[keyPath: selected.keyPath] },
                    set: {
                        adjustments[keyPath: selected.keyPath] = $0
                        onChange()
                    }
                ),
                in: selected.range
            )
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AdjustmentParameter.all) { parameter in
                        Button {
                            selectedParameterID = parameter.id
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: parameter.systemImage)
                                    .font(.body)
                                    .frame(width: 30, height: 30)
                                    .background(
                                        selectedParameterID == parameter.id
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.18),
                                        in: Circle()
                                    )
                                    .foregroundStyle(
                                        selectedParameterID == parameter.id
                                        ? .white
                                        : .primary
                                    )

                                Text(parameter.title)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var valueText: String {
        let value = adjustments[keyPath: selected.keyPath]
        if selected.range.lowerBound < 0 {
            return String(format: "%+.0f", value * 100)
        }
        return String(format: "%.0f", value * 100)
    }
}
