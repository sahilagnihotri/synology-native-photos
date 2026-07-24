import SwiftUI
import PhotosCore

/// Form state for `LoginView`, kept separate from the view so the
/// OTP-visibility and error-text logic driven by `AuthPhase` can be tested
/// without instantiating SwiftUI.
@MainActor
@Observable
final class LoginFormModel {
    private let auth: AuthStateMachine

    var host: String = "https://"
    var username: String = ""
    var password: String = ""
    var otpCode: String = ""
    var showOtp: Bool = false
    var isBusy: Bool = false
    var errorText: String?

    init(auth: AuthStateMachine) {
        self.auth = auth
    }

    /// Submits the form: a plain login while `showOtp` is false, or the
    /// OTP retry once the state machine has asked for a code. Reflects
    /// whatever phase the attempt lands on back into the form via `sync`.
    func submit() async {
        isBusy = true
        defer { isBusy = false }
        let otp = showOtp && !otpCode.isEmpty ? otpCode : nil
        await auth.attemptLogin(host: host, username: username, password: password, otpCode: otp, pinnedCertDer: nil)
        sync(with: auth.phase)
    }

    /// Reflects the auth phase into the form UI (OTP field visibility and
    /// the error banner). Never touches `host`/`username`/`password`/`otpCode`
    /// so the user's typed input survives a failed attempt.
    func sync(with phase: AuthPhase) {
        switch phase {
        case .needsOtp:
            showOtp = true
            errorText = "Enter your two-factor code to continue."
        case .invalid(let message):
            errorText = message
        case .valid:
            errorText = nil
        case .expired:
            errorText = "Your session expired. Sign in again."
        default:
            break
        }
    }
}

/// The login form: host, username, password, and a two-factor code field
/// that appears once the state machine reports `needsOtp`. All state lives
/// in `LoginFormModel`; this view only renders it and forwards submit taps.
struct LoginView: View {
    @State private var model: LoginFormModel
    private let auth: AuthStateMachine

    init(auth: AuthStateMachine) {
        self.auth = auth
        _model = State(initialValue: LoginFormModel(auth: auth))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Synology Photos").font(.title2).bold()
            TextField("Server, e.g. https://192.168.1.10:5001", text: $model.host)
                .textContentType(.URL).accessibilityIdentifier("login.host")
            TextField("Username", text: $model.username)
                .textContentType(.username).accessibilityIdentifier("login.username")
            SecureField("Password", text: $model.password)
                .textContentType(.password).accessibilityIdentifier("login.password")
            if model.showOtp {
                TextField("Two-factor code", text: $model.otpCode)
                    .accessibilityIdentifier("login.otp")
            }
            if let err = model.errorText {
                Text(err).foregroundStyle(.red).font(.callout).accessibilityIdentifier("login.error")
            }
            Button(model.showOtp ? "Verify" : "Sign In") { Task { await model.submit() } }
                .disabled(model.isBusy).accessibilityIdentifier("login.submit")
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: auth.phase) { _, newPhase in model.sync(with: newPhase) }
    }
}
