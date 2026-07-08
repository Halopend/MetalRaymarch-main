//
//  StorageModeChoiceSheet.swift
//  Threshold
//
//  One-time first-run prompt: choose where scenes, animations, and presets are
//  stored — On This Device (sandbox) or iCloud Drive. The chosen folder is the
//  source of truth; the choice is changeable later in Settings, and switching
//  merges both stores so nothing is lost.
//

import SwiftUI

struct StorageModeChoiceSheet: View {
    let onChoose: (StorageMode) -> Void
    @State private var selection: StorageMode = .local

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 40))
                    .foregroundStyle(.cyan)
                Text("Where should Threshold keep your work?")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Your scenes, animations, and presets. You can change this anytime in Settings — switching merges both, so nothing is lost. A local safety backup is always kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(StorageMode.allCases, id: \.self) { mode in
                    choiceRow(mode)
                }
            }

            Button {
                onChoose(selection)
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.cyan)
        }
        .padding(24)
        .frame(maxWidth: 460)
    }

    @ViewBuilder
    private func choiceRow(_ mode: StorageMode) -> some View {
        let selected = selection == mode
        Button {
            selection = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.iconName)
                    .font(.title2)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName).font(.headline)
                    Text(mode == .local
                         ? "Private to this device."
                         : "Synced across your devices and browseable in the Files app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .cyan : .secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(selected ? Color.cyan.opacity(0.12) : Color.gray.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.cyan : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
