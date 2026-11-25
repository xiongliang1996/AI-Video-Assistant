//
//  CollectionSheet.swift
//  新建 / 重命名素材集合的输入弹窗
//

import SwiftUI

struct CollectionNameSheet: View {
    let title: String
    let placeholder: String
    let confirmTitle: String
    var icon: String = "folder.badge.plus"
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String,
         initialName: String = "",
         placeholder: String = "例如：口播素材 / 空镜 / 配乐",
         confirmTitle: String = "创建",
         icon: String = "folder.badge.plus",
         onSubmit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.icon = icon
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }

            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panel2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(focused ? Theme.accent.opacity(0.5) : Theme.line2, lineWidth: 1)
                )
                .focused($focused)
                .onSubmit(submit)

            HStack(spacing: 8) {
                Text("重名会自动加序号")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Text("取消").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(SoftButtonStyle(height: 28))
                .keyboardShortcut(.cancelAction)

                Button {
                    submit()
                } label: {
                    Text(confirmTitle).font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PrimaryButtonStyle(height: 28))
                .disabled(trimmed.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(Theme.panel)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
