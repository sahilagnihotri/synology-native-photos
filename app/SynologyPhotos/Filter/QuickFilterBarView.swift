import SwiftUI
import PhotosCore

/// The Quick Filter affordance on the library toolbar: a button that opens a
/// popover with the three local-index facets (file type, date taken, rating).
/// Applying narrows the library grid to the matching photos; clearing returns
/// to the plain library. Mirrors `SearchFilterBarView`'s button+popover shape
/// so the two filter controls read the same, but this one is local-only (no
/// facet catalog to fetch) and applies to the space-backed library grid rather
/// than to search results.
///
/// People, Places, Tags, and Favorites are intentionally absent: those are
/// server-side clusters reached from the sidebar, not local-index facets.
struct QuickFilterBarView: View {
    let model: QuickFilterModel
    /// Called when Apply is pressed, so the caller can switch the grid over to
    /// the built `FilterQuery`.
    let onApply: () -> Void
    /// Called when Clear is pressed (after the model has been cleared), so the
    /// caller can drop the filter and return to the plain library.
    let onClear: () -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Filter", systemImage: model.hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("quickfilter.button")
        .popover(isPresented: $isPresented) {
            QuickFilterPopoverContent(model: model, onApply: {
                isPresented = false
                onApply()
            }, onClear: {
                model.clear()
                isPresented = false
                onClear()
            })
            .frame(width: 300)
            .padding()
        }
    }
}

/// The popover's content: the file-type, date-range, and rating controls plus
/// a Clear/Apply footer. Split out from `QuickFilterBarView` so the popover's
/// own layout/state stays testable and readable independent of the button that
/// opens it, matching `SearchFilterPopoverContent`.
private struct QuickFilterPopoverContent: View {
    let model: QuickFilterModel
    let onApply: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File Type").font(.headline)
            Picker("File Type", selection: fileTypeBinding) {
                Text("All").tag(FileTypeChoice.all)
                Text("Photos").tag(FileTypeChoice.photo)
                Text("Videos").tag(FileTypeChoice.video)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("quickfilter.filetype")

            Divider()

            Text("Date Taken").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("From", isOn: startDateEnabled)
                    .accessibilityIdentifier("quickfilter.startdate.toggle")
                if model.startDate != nil {
                    DatePicker("", selection: startDateBinding, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("quickfilter.startdate.picker")
                }
                Toggle("To", isOn: endDateEnabled)
                    .accessibilityIdentifier("quickfilter.enddate.toggle")
                if model.endDate != nil {
                    DatePicker("", selection: endDateBinding, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("quickfilter.enddate.picker")
                }
            }

            Divider()

            Text("Rating").font(.headline)
            Picker("Rating", selection: ratingBinding) {
                Text("All").tag(UInt8(0))
                ForEach(1...5, id: \.self) { stars in
                    Text("\(stars)+ Stars").tag(UInt8(stars))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier("quickfilter.rating")

            Divider()

            HStack {
                Button("Clear", action: onClear)
                    .accessibilityIdentifier("quickfilter.clear")
                Spacer()
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("quickfilter.apply")
            }
        }
    }

    private var fileTypeBinding: Binding<FileTypeChoice> {
        Binding(
            get: {
                switch model.mediaKind {
                case .some(.photo): return .photo
                case .some(.video): return .video
                default: return .all
                }
            },
            set: { choice in
                switch choice {
                case .all: model.mediaKind = nil
                case .photo: model.mediaKind = .photo
                case .video: model.mediaKind = .video
                }
            }
        )
    }

    /// Rating floor as a plain `UInt8`, with `0` standing in for All so the
    /// menu can carry a single non-optional selection. Mapped back to `nil`
    /// (no rating constraint) when All is chosen.
    private var ratingBinding: Binding<UInt8> {
        Binding(
            get: { model.minRating ?? 0 },
            set: { model.minRating = $0 == 0 ? nil : $0 }
        )
    }

    private var startDateEnabled: Binding<Bool> {
        Binding(
            get: { model.startDate != nil },
            set: { enabled in model.startDate = enabled ? (model.startDate ?? Date()) : nil }
        )
    }

    private var endDateEnabled: Binding<Bool> {
        Binding(
            get: { model.endDate != nil },
            set: { enabled in model.endDate = enabled ? (model.endDate ?? Date()) : nil }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(get: { model.startDate ?? Date() }, set: { model.startDate = $0 })
    }

    private var endDateBinding: Binding<Date> {
        Binding(get: { model.endDate ?? Date() }, set: { model.endDate = $0 })
    }
}

/// The three file-type choices the segmented picker offers. A dedicated,
/// non-optional enum keeps the `Picker` selection type simple and avoids the
/// fragile optional-tag matching a `MediaKind?` selection would need; the
/// binding above maps it to and from the model's `MediaKind?`.
private enum FileTypeChoice: Hashable {
    case all
    case photo
    case video
}
