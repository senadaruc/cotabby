import SwiftUI

/// File overview:
/// The Memory pane's "Answer Questions" settings: drafting an answer from memory when a message
/// asks the user something, how sure memory must be before offering one, and a way to try it.
///
/// Which sources answers may draw on is set per source ("Use for answers" in the Sources section),
/// and per app or window from the field icon. Presentation only: changes go through
/// `MemoryControlModel`.
struct MemoryAnswersSection: View {
    @ObservedObject var control: MemoryControlModel
    @State private var question = ""

    var body: some View {
        if let answers = control.configuration?.answers {
            Section {
                Toggle(isOn: Binding(
                    get: { answers.enabled },
                    set: { enabled in
                        var updated = answers
                        updated.enabled = enabled
                        control.updateAnswers(updated)
                    }
                )) {
                    SettingsRowLabel(
                        title: "Answer Questions",
                        description: "When you open an empty reply to a message that asks you something, draft an answer " +
                            "from your memory and show it with the messages it came from. Tab inserts it, Esc or typing " +
                            "dismisses it. Drafted on this Mac; never sent to an endpoint model.",
                        systemImage: "text.bubble"
                    )
                }

                if answers.enabled {
                    VStack(alignment: .leading) {
                        Text("Offer an answer when memory is at least \(Int((answers.minimumConfidence * 100).rounded()))% sure")
                        Slider(value: Binding(
                            get: { answers.minimumConfidence },
                            set: { value in
                                var updated = answers
                                updated.minimumConfidence = value
                                control.updateAnswers(updated)
                            }
                        ), in: 0.2...0.8, step: 0.05)
                        Text("Higher shows fewer, safer answers. Answers whose numbers or names are not in your messages are never shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let sources = control.sources.filter { $0.enabled && $0.isAnswerSource }.map(\.title)
                    Text(sources.isEmpty
                        ? "No source is used for answers yet: turn on \"Use for answers\" under Sources."
                        : "Facts come from: \(sources.joined(separator: ", ")), and the conversation you reply in.")
                        .font(.caption)
                        .foregroundStyle(sources.isEmpty ? .orange : .secondary)

                    HStack {
                        TextField("Try a question someone might ask you", text: $question)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { control.searchAnswers(question: question) }
                        Button("Find Facts") { control.searchAnswers(question: question) }
                            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Shows what an answer would draw on (in the Playground below).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Answers")
            }
            .settingsItem(.memoryAnswers)
        }
    }
}
