import SwiftUI
import PhotosCore

/// The filter affordance attached to the library's search field: a button
/// that opens a popover with the one working filter (a date range), plus a
/// browse-only view of the camera/location/media-type facets DSM reports
/// but that have no working filter param on this NAS (see
/// `models::Facet`'s doc comment for the probe). Selecting a date range (with
/// or without an active keyword) narrows the search; clearing the filter
/// returns to whatever the keyword alone would already show.
///
/// Read-only: there is no way to save this selection, matching every other
/// search affordance in the app.
struct SearchFilterBarView: View {
    let model: SearchFilterModel
    /// Called whenever the committed filter selection changes (Apply is
    /// pressed, or Clear is pressed), so the caller can re-run the search
    /// with the new `SearchFilters`.
    let onApply: () -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
            Task { await model.loadFacetsIfNeeded() }
        } label: {
            Label("Filters", systemImage: model.hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("search.filters.button")
        .popover(isPresented: $isPresented) {
            SearchFilterPopoverContent(model: model, onApply: {
                isPresented = false
                onApply()
            }, onClear: {
                model.clear()
                isPresented = false
                onApply()
            })
            .frame(width: 320)
            .padding()
        }
    }
}

/// The popover's content: the date range controls (the one working filter)
/// followed by a browse-only list of camera/location facets. Split out from
/// `SearchFilterBarView` so the popover's own state/layout stays testable
/// and readable independent of the button that opens it.
private struct SearchFilterPopoverContent: View {
    let model: SearchFilterModel
    let onApply: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Date Range")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("From", isOn: startDateEnabled)
                    .accessibilityIdentifier("search.filters.startdate.toggle")
                if model.startDate != nil {
                    DatePicker("", selection: startDateBinding, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("search.filters.startdate.picker")
                }
                Toggle("To", isOn: endDateEnabled)
                    .accessibilityIdentifier("search.filters.enddate.toggle")
                if model.endDate != nil {
                    DatePicker("", selection: endDateBinding, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("search.filters.enddate.picker")
                }
            }

            Divider()

            facetBrowseSection

            HStack {
                Button("Clear", action: onClear)
                    .accessibilityIdentifier("search.filters.clear")
                Spacer()
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("search.filters.apply")
            }
        }
    }

    /// Browse-only section for camera/location/media-type: DSM reports
    /// these facets, but no working filter param exists for them on this
    /// NAS (see `models::Facet`'s doc comment), so they are shown for
    /// context only, never selectable. This keeps the catalog visible
    /// (useful for confirming what DSM has indexed) without pretending a
    /// tap here would actually narrow results.
    @ViewBuilder
    private var facetBrowseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera & Location")
                .font(.headline)
            if model.isLoadingFacets {
                ProgressView().accessibilityIdentifier("search.filters.facets.loading")
            } else if let loadError = model.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("search.filters.facets.error")
            } else if let facets = model.facets {
                facetSummary(facets)
            }
            Text("Browsing only; the NAS does not yet support filtering search by camera or location.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func facetSummary(_ facets: SearchFacets) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !facets.cameras.isEmpty {
                facetRow(title: "Cameras", names: facets.cameras.map(\.name))
            }
            if !facets.geocodings.isEmpty {
                facetRow(title: "Places", names: facets.geocodings.map(\.name))
            }
            if facets.cameras.isEmpty && facets.geocodings.isEmpty {
                Text("No camera or location metadata indexed yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("search.filters.facets.summary")
    }

    private func facetRow(title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).fontWeight(.semibold)
            Text(names.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
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
