//
//  AnimationCurveViews.swift
//  Threshold
//
//  Easing-curve previews and the song picker sheet. Extracted from
//  AnimationViews.swift during the Phase 3 architecture refactor. These views
//  are fully self-contained (no dependency on AnimationViews internals).
//

import SwiftUI

// MARK: - Bezier Curve Preview

/// Visual preview of a cubic Bezier easing curve.
/// Shows the curve from (0,0) to (1,1) with control point indicators.
struct BezierCurvePreview: View {
    let handle: BezierHandle
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padding: CGFloat = 16
            let plotW = w - padding * 2
            let plotH = h - padding * 2
            
            Canvas { context, size in
                // Background grid
                let gridColor = Color.secondary.opacity(0.15)
                for i in 0...4 {
                    let frac = CGFloat(i) / 4.0
                    // Vertical
                    let x = padding + frac * plotW
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: x, y: padding)); p.addLine(to: CGPoint(x: x, y: padding + plotH)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                    // Horizontal
                    let y = padding + frac * plotH
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: padding, y: y)); p.addLine(to: CGPoint(x: padding + plotW, y: y)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                }
                
                // Diagonal reference (linear)
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: padding, y: padding + plotH))
                        p.addLine(to: CGPoint(x: padding + plotW, y: padding))
                    },
                    with: .color(Color.secondary.opacity(0.25)), lineWidth: 1
                )
                
                // Bezier curve
                let curvePath = Path { p in
                    let steps = 60
                    for i in 0...steps {
                        let t = Float(i) / Float(steps)
                        let eased = CubicBezier.evaluate(t, handle: handle)
                        let x = padding + CGFloat(t) * plotW
                        let y = padding + plotH - CGFloat(eased) * plotH
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                context.stroke(curvePath, with: .color(.blue), lineWidth: 2.5)
                
                // Control point 1 handle line
                let cp1 = CGPoint(x: padding + CGFloat(handle.cp1x) * plotW,
                                  y: padding + plotH - CGFloat(handle.cp1y) * plotH)
                let start = CGPoint(x: padding, y: padding + plotH)
                context.stroke(
                    Path { p in p.move(to: start); p.addLine(to: cp1) },
                    with: .color(.orange.opacity(0.6)), lineWidth: 1
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: cp1.x - 4, y: cp1.y - 4, width: 8, height: 8)),
                    with: .color(.orange)
                )
                
                // Control point 2 handle line
                let cp2 = CGPoint(x: padding + CGFloat(handle.cp2x) * plotW,
                                  y: padding + plotH - CGFloat(handle.cp2y) * plotH)
                let end = CGPoint(x: padding + plotW, y: padding)
                context.stroke(
                    Path { p in p.move(to: end); p.addLine(to: cp2) },
                    with: .color(.green.opacity(0.6)), lineWidth: 1
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: cp2.x - 4, y: cp2.y - 4, width: 8, height: 8)),
                    with: .color(.green)
                )
                
                // Start/end dots
                context.fill(
                    Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)),
                    with: .color(.primary)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)),
                    with: .color(.primary)
                )
            }
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Easing Curve Preview (non-Bezier)

/// Simple curve preview that uses EasingFunction.apply() to draw the easing shape.
struct EasingCurvePreview: View {
    let easing: EasingFunction
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padding: CGFloat = 16
            let plotW = w - padding * 2
            let plotH = h - padding * 2
            
            Canvas { context, _ in
                // Background grid
                let gridColor = Color.secondary.opacity(0.15)
                for i in 0...4 {
                    let frac = CGFloat(i) / 4.0
                    let x = padding + frac * plotW
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: x, y: padding)); p.addLine(to: CGPoint(x: x, y: padding + plotH)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                    let y = padding + frac * plotH
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: padding, y: y)); p.addLine(to: CGPoint(x: padding + plotW, y: y)) },
                        with: .color(gridColor), lineWidth: 0.5
                    )
                }
                
                // Diagonal reference (linear)
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: padding, y: padding + plotH))
                        p.addLine(to: CGPoint(x: padding + plotW, y: padding))
                    },
                    with: .color(Color.secondary.opacity(0.25)), lineWidth: 1
                )
                
                // Easing curve
                let curvePath = Path { p in
                    let steps = 60
                    for i in 0...steps {
                        let t = Float(i) / Float(steps)
                        let eased = easing.apply(t)
                        let x = padding + CGFloat(t) * plotW
                        let y = padding + plotH - CGFloat(eased) * plotH
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                context.stroke(curvePath, with: .color(.blue), lineWidth: 2.5)
            }
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Song Picker Sheet

/// A compact song browser for attaching a library song to a scene.
struct SongPickerSheet: View {
    let musicService: MusicService?
    let onSelect: (UnifiedTrack) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let music = musicService, let provider = music.activeProvider {
                    let songs = filteredSongs(from: provider)
                    List(songs, id: \.id) { track in
                        Button {
                            onSelect(track)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: AppIcons.musicNote)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: AppIcons.plusCircle)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .overlay {
                        if songs.isEmpty {
                            ContentUnavailableView(
                                "No Songs",
                                systemImage: AppIcons.musicNote,
                                description: Text(searchText.isEmpty ? "Your library is empty." : "No songs match your search.")
                            )
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Music Service",
                        systemImage: AppIcons.musicNoteList,
                        description: Text("Connect a music service first.")
                    )
                }
            }
            .navigationTitle("Choose a Song")
            .searchable(text: $searchText, prompt: "Search songs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    private func filteredSongs(from provider: MusicServiceProvider) -> [UnifiedTrack] {
        let all = provider.librarySongs
        guard !searchText.isEmpty else { return all }
        let query = searchText.lowercased()
        return all.filter {
            $0.title.lowercased().contains(query) ||
            $0.artist.lowercased().contains(query)
        }
    }
}
