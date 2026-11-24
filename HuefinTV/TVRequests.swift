import SwiftUI

/// Ask for movies and shows that aren't on the server yet (Seerr / Jellyseerr), and approve others' requests if you manage it.
struct TVRequestsView: View {
    @Environment(AppState.self) private var app
    @State private var seerr = Seerr.shared
    @State private var tab = 0
    @State private var trending: [Seerr.Result] = []
    @State private var requests: [Seerr.Request] = []
    @State private var details: [Int: (String?, String?)] = [:]
    @State private var picked: Seerr.Result?
    @State private var requested: Set<Int> = []

    var body: some View {
        Group {
            if seerr.isConfigured { content } else { TVSeerrConnect() }
        }
        .task(id: app.session?.key) { await seerr.activate(accountKey: app.session?.key, jellyfinURL: app.session?.serverURL) }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Picker("", selection: $tab) {
                    Text("Discover").tag(0)
                    Text(seerr.canManage ? "All requests" : "My requests").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 800)
                if tab == 0 {
                    Text("Popular right now. Use Search to find anything else.").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 200), spacing: 40)], spacing: 44) {
                        ForEach(trending) { r in
                            VStack(alignment: .leading, spacing: 10) {
                                Button { picked = r } label: {
                                    ZStack(alignment: .bottom) {
                                        TVImage(url: r.posterURL)
                                        if let s = requested.contains(r.id) ? "Requested ✓" : r.statusText {
                                            Text(s).font(.caption.bold()).padding(8).frame(maxWidth: .infinity)
                                                .background((r.status == 5 ? Theme.green : Theme.violet).opacity(0.9))
                                        }
                                    }.frame(width: 200, height: 300)
                                }.buttonStyle(.card)
                                Text(r.title).font(.caption).lineLimit(1)
                            }.frame(width: 200)
                        }
                    }
                } else {
                    if requests.isEmpty { Text("No requests yet.").foregroundStyle(.secondary) }
                    ForEach(requests) { r in
                        HStack(spacing: 30) {
                            TVImage(url: details[r.id]?.1.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") })
                                .frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(details[r.id]?.0 ?? "…").font(.headline)
                                Text(statusText(r)).foregroundStyle(r.status == 3 ? Theme.red : .secondary)
                                if seerr.canManage, !r.requestedBy.isEmpty { Text("Asked by \(r.requestedBy)").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if seerr.canManage && r.status == 1 {
                                Button { Task { try? await seerr.approve(r.id); requests = await seerr.requests() } } label: { Label("Approve", systemImage: "checkmark") }.hueAction(primary: true, hue: Theme.green)
                                Button { Task { try? await seerr.decline(r.id); requests = await seerr.requests() } } label: { Label("Decline", systemImage: "xmark") }.hueAction()
                            }
                        }
                        .padding(20).background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
                        .focusable()
                        .task { if details[r.id] == nil { let d = await seerr.details(r); details[r.id] = (d.title, d.poster) } }
                    }
                }
            }.padding(80)
        }
        .task(id: tab) {
            if tab == 0 { trending = await seerr.trending() } else { requests = await seerr.requests() }
        }
        .sheet(item: $picked) { r in
            TVSeerrDetail(result: r, alreadyRequested: requested.contains(r.id)) { requested.insert(r.id) }
        }
    }

    private func statusText(_ r: Seerr.Request) -> String {
        if r.mediaStatus == 5 { return "Available to watch" }
        switch r.status { case 1: return "Waiting for approval"; case 2: return "Approved, downloading"; case 3: return "Declined"; default: return "Requested" }
    }
}

/// One title from Seerr with the Request button.
struct TVSeerrDetail: View {
    let result: Seerr.Result
    var alreadyRequested = false
    var onRequested: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            TVImage(url: result.posterURL).frame(width: 340, height: 510).clipShape(RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 24) {
                Text(result.title).font(.system(size: 44, weight: .heavy))
                Text([result.year, result.mediaType == "tv" ? "TV show" : "Movie"].compactMap { $0 }.joined(separator: "  ·  ")).foregroundStyle(.secondary)
                if let s = result.statusText { Text(s).foregroundStyle(Theme.violet).font(.headline) }
                Text(result.overview ?? "").font(.callout).lineLimit(8)
                if result.status == 5 {
                    Text("It's already on your server. Find it in Search to watch.").foregroundStyle(.secondary)
                } else {
                    Button {
                        busy = true
                        Task {
                            do { try await Seerr.shared.request(result); done = true; onRequested() }
                            catch { self.error = "Couldn't request it: \(error.localizedDescription)" }
                            busy = false
                        }
                    } label: {
                        Label(done || alreadyRequested ? "Requested!" : (result.mediaType == "tv" ? "Request all seasons" : "Request"),
                              systemImage: done || alreadyRequested ? "checkmark.circle.fill" : "plus.circle.fill")
                    }
                    .hueAction(primary: true, hue: Theme.violet)
                    .disabled(busy || done || alreadyRequested || (result.status ?? 0) >= 2)
                }
                if let error { Text(error).foregroundStyle(Theme.red) }
                Button("Close") { dismiss() }.hueAction()
            }.frame(maxWidth: 1000, alignment: .leading)
        }
        .padding(100)
    }
}

/// Sign in to Seerr once (with your Jellyfin password; Huefin doesn't keep it).
struct TVSeerrConnect: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Connect requests").font(.title2.bold())
            Text("Requests use Seerr (Jellyseerr). Sign in once with your Jellyfin password; Huefin doesn't keep it.")
                .font(.title3).foregroundStyle(.secondary)
            TextField("Seerr address (e.g. https://requests.example.com)", text: $address)
                .textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
            Text("Signing in as \(app.session?.userName ?? "")").foregroundStyle(.secondary)
            SecureField("Your Jellyfin password", text: $password)
            Button {
                busy = true; error = nil
                Task {
                    do { try await Seerr.shared.signIn(address: address, username: app.session?.userName ?? "", password: password) }
                    catch { self.error = "Couldn't sign in. Check the address and password." }
                    password = ""; busy = false
                }
            } label: { HStack { if busy { ProgressView() }; Text("Connect").bold() } }
            .buttonStyle(TVHueButtonStyle(filled: true, hue: Theme.violet))
            .disabled(busy || address.isEmpty || password.isEmpty)
            if let error { Text(error).foregroundStyle(Theme.red) }
        }
        .frame(maxWidth: 1100).padding(80)
        .task {
            if address.isEmpty {
                if let u = Seerr.shared.baseURL { address = u.absoluteString }
                else if let u = await Seerr.discover(near: app.session?.serverURL) { address = u.absoluteString }
            }
        }
    }
}
