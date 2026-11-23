import SwiftUI

/// Ask for movies and shows that aren't on the server yet (through Seerr), and approve requests.
struct RequestsView: View {
    @Environment(AppState.self) private var app
    @State private var seerr = Seerr.shared
    @State private var tab = 0
    @State private var query = ""
    @State private var results: [Seerr.Result] = []
    @State private var requests: [Seerr.Request] = []
    @State private var selected: Seerr.Result?

    var body: some View {
        Group {
            if !seerr.isConfigured {
                SeerrSetupView()
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("Discover").tag(0)
                        Text(seerr.canManage ? "All requests" : "My requests").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    if tab == 0 { discover } else { requestList }
                }
            }
        }
        .background(TintedBackdrop(color: nil))
        .navigationTitle("Requests")
        .toolbar {
            if seerr.isConfigured {
                Menu {
                    Button("Sign out of Seerr", role: .destructive) { Task { await seerr.signOut() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: app.session?.key) {
            if seerr.baseURL == nil || !seerr.signedIn { await seerr.activate(accountKey: app.session?.key) }
        }
        .sheet(item: $selected) { r in SeerrDetailSheet(result: r) }
    }

    private var discover: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                ForEach(results) { r in
                    Button { selected = r } label: { SeerrPoster(result: r) }.buttonStyle(CardPressStyle())
                }
            }
            .padding()
        }
        .searchable(text: $query, prompt: "Find a movie or show")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let q = query.trimmingCharacters(in: .whitespaces)
            results = q.count >= 2 ? await seerr.search(q) : await seerr.trending()
        }
    }

    private var requestList: some View {
        List {
            if requests.isEmpty { Text("No requests yet.").foregroundStyle(.secondary) }
            ForEach(requests) { r in
                HStack(spacing: 12) {
                    RemoteImage(url: r.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w154\($0)") })
                        .frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.title ?? "…").font(.body.weight(.semibold)).lineLimit(1)
                        Text(statusText(r)).font(.caption).foregroundStyle(r.status == 3 ? Theme.red : .secondary)
                        if seerr.canManage, !r.requestedBy.isEmpty {
                            Text("Asked by \(r.requestedBy)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if seerr.canManage && r.status == 1 {
                        Button { act { try await seerr.approve(r.id) } } label: { Image(systemName: "checkmark.circle.fill").font(.title2) }
                            .buttonStyle(.borderless).tint(Theme.green)
                        Button { act { try await seerr.decline(r.id) } } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                            .buttonStyle(.borderless).tint(Theme.red)
                    }
                }
                .listRowBackground(Theme.card)
                .task {
                    guard r.title == nil else { return }
                    let d = await seerr.details(r)
                    if let i = requests.firstIndex(where: { $0.id == r.id }) {
                        requests[i].title = d.title ?? "Unknown"
                        requests[i].posterPath = d.poster
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { requests = await seerr.requests() }
        .task { requests = await seerr.requests() }
    }

    private func statusText(_ r: Seerr.Request) -> String {
        if r.mediaStatus == 5 { return "Available to watch" }
        switch r.status {
        case 1: return "Waiting for approval"
        case 2: return "Approved, downloading"
        case 3: return "Declined"
        default: return "Requested"
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            try? await work()
            requests = await seerr.requests()
        }
    }
}

struct SeerrPoster: View {
    let result: Seerr.Result
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                .overlay { RemoteImage(url: result.posterURL) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let s = result.statusText {
                        Text(s == "Available" ? "✓" : "•••").font(.caption2.weight(.heavy))
                            .padding(5).background(s == "Available" ? Theme.green : Theme.orange, in: Circle())
                            .foregroundStyle(.black).padding(6)
                    }
                }
            Text(result.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text([result.year, result.mediaType == "tv" ? "Show" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SeerrDetailSheet: View {
    let result: Seerr.Result
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    RemoteImage(url: result.posterURL).frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.title).font(.title2.weight(.bold))
                        Text([result.year, result.mediaType == "tv" ? "TV show" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        if let s = result.statusText { Label(s, systemImage: "info.circle").font(.subheadline) }
                    }
                }
                if let o = result.overview { Text(o).font(.callout) }
                if result.status == 5 {
                    Text("It's already on your server. Search for it in Prism to watch.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button {
                        busy = true
                        Task {
                            do { try await Seerr.shared.request(result); done = true }
                            catch { self.error = "Couldn't request it: \(error.localizedDescription)" }
                            busy = false
                        }
                    } label: {
                        Label(done ? "Requested!" : (result.mediaType == "tv" ? "Request all seasons" : "Request"),
                              systemImage: done ? "checkmark.circle.fill" : "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || done || (result.status ?? 0) >= 2)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }
}

struct SeerrSetupView: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Seerr address (e.g. https://requests.example.com)", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Username", value: app.session?.userName ?? "")
                SecureField("Your Jellyfin password", text: $password)
            } header: {
                Text("Connect requests")
            } footer: {
                Text("Requests use Seerr (Jellyseerr). Sign in once with your Jellyfin password; Prism doesn't keep it.")
            }
            Button {
                busy = true
                error = nil
                Task {
                    do { try await Seerr.shared.signIn(address: address, username: app.session?.userName ?? "", password: password) }
                    catch { self.error = "Couldn't sign in. Check the address and password." }
                    password = ""
                    busy = false
                }
            } label: {
                HStack { Text("Connect"); if busy { Spacer(); ProgressView() } }
            }
            .disabled(busy || address.isEmpty || password.isEmpty)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .scrollContentBackground(.hidden)
    }
}
