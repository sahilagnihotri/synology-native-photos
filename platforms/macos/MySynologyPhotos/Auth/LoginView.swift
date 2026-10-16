import SwiftUI
import PhotosCore

/// Form state for `LoginView`, kept separate from the view so the
/// OTP-visibility, cert-approval gating, and error-text logic driven by
/// `AuthPhase`/`CertTrustPhase` can be tested without instantiating SwiftUI.
///
/// Submitting goes through two gates, in order:
/// 1. Certificate trust (`cert`): on the first submit for a host with no
///    pinned cert, this fetches and shows the fingerprint instead of
///    logging in at all, so credentials are never sent before the user has
///    approved the server's identity. Approving lets a resubmit proceed.
/// 2. The actual login, with whatever pin/device-token/insecure-toggle
///    state is now in effect.
@MainActor
@Observable
final class LoginFormModel {
    // Not `private`: `@testable import` needs this to assert which phase a
    // submit landed on (remember-me and device-token tests both check the
    // resulting `AuthPhase`, not just what got written to the Keychain).
    let auth: AuthStateMachine
    let cert: CertApprovalViewModel

    // Where prefill gets saved on every submit. The app leaves this at
    // `.standard`; tests inject an isolated suite so they never touch the
    // real app's saved login prefill.
    private let defaults: UserDefaults

    var host: String
    var username: String
    var password: String = ""
    var otpCode: String = ""
    var showOtp: Bool = false
    var isBusy: Bool = false
    var errorText: String?
    var rememberMe: Bool
    var allowUntrustedTls: Bool

    init(
        auth: AuthStateMachine,
        client: PhotosCoreProtocol,
        defaults: UserDefaults = .standard,
        prefs: LoginPreferences? = nil
    ) {
        self.auth = auth
        self.cert = CertApprovalViewModel(client: client)
        self.defaults = defaults
        let prefs = prefs ?? LoginPreferencesStore.load(defaults: defaults)
        self.host = prefs.host.isEmpty ? "https://" : prefs.host
        self.username = prefs.username
        self.rememberMe = prefs.rememberMe
        self.allowUntrustedTls = prefs.allowUntrustedTls
    }

    /// Submits the form. First makes sure the host's certificate is
    /// trusted (fetching + surfacing it for approval if this is the first
    /// time this host has been seen), then performs a plain login while
    /// `showOtp` is false or the OTP retry once the state machine has
    /// asked for a code. Reflects whatever phase the attempt lands on back
    /// into the form via `sync`. Saves non-secret prefill (host, username,
    /// the two toggles) unconditionally, since none of it is sensitive and
    /// all of it is useful to have back on the next launch regardless of
    /// whether the login itself succeeds.
    func submit() async {
        isBusy = true
        defer { isBusy = false }
        LoginPreferencesStore.save(
            LoginPreferences(host: host, username: username, rememberMe: rememberMe, allowUntrustedTls: allowUntrustedTls),
            defaults: defaults)

        await cert.checkHost(host)
        if case .needsApproval = cert.phase {
            // Stop here: the view now shows the fingerprint/subject and an
            // Approve button. Nothing is sent to the server until the user
            // approves (see `approveCert`) and resubmits.
            return
        }
        if case .failed(let message) = cert.phase {
            errorText = message
            return
        }

        let otp = showOtp && !otpCode.isEmpty ? otpCode : nil
        let deviceToken = try? KeychainDeviceToken.load(host: host, username: username)
        await auth.attemptLogin(
            host: host,
            username: username,
            password: password,
            otpCode: otp,
            pinnedCertDer: cert.pinnedCertDer,
            allowUntrustedTls: allowUntrustedTls,
            deviceToken: deviceToken ?? nil,
            rememberMe: rememberMe
        )
        sync(with: auth.phase)
    }

    /// Approves the certificate currently pending in `cert.phase` and
    /// immediately retries the submit, now that a pin is in place.
    func approveCertAndRetry() async {
        cert.approve(host: host)
        await submit()
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

/// The login form: host, username, password, a two-factor code field that
/// appears once the state machine reports `needsOtp`, a remember-me
/// toggle, and the insecure "skip certificate check" last resort. Between
/// entering credentials and the actual login sits the trust-on-first-use
/// certificate approval step: the first time a host is seen, submitting
/// shows the server's fingerprint/subject for the user to approve rather
/// than logging in.
struct LoginView: View {
    @State private var model: LoginFormModel
    @State private var showPassword = false
    private let auth: AuthStateMachine

    init(auth: AuthStateMachine, client: PhotosCoreProtocol) {
        self.auth = auth
        _model = State(initialValue: LoginFormModel(auth: auth, client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to MySynology Photos").font(.title2).bold()
            TextField("Server, e.g. https://192.168.1.10:5001", text: $model.host)
                .textContentType(.URL).accessibilityIdentifier("login.host")
            TextField("Username", text: $model.username)
                .textContentType(.username).accessibilityIdentifier("login.username")
            HStack {
                Group {
                    if showPassword {
                        TextField("Password", text: $model.password)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Password", text: $model.password)
                            .textContentType(.password)
                    }
                }
                .accessibilityIdentifier("login.password")
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                .accessibilityIdentifier("login.password.reveal")
            }
            if model.showOtp {
                TextField("Two-factor code", text: $model.otpCode)
                    .accessibilityIdentifier("login.otp")
            }
            Toggle("Remember me", isOn: $model.rememberMe)
                .accessibilityIdentifier("login.rememberme")
            Toggle("Skip certificate check (insecure, not recommended)", isOn: $model.allowUntrustedTls)
                .foregroundStyle(.red)
                .accessibilityIdentifier("login.insecuretoggle")

            if case .needsApproval(let info) = model.cert.phase {
                CertApprovalView(info: info) {
                    Task { await model.approveCertAndRetry() }
                }
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

/// Shown once per host, the first time its certificate has never been
/// pinned: the server's SHA-256 fingerprint and subject, for the user to
/// visually confirm against what they expect (e.g. by comparing it to the
/// fingerprint shown in DSM's own control panel) before approving.
///
/// Approving is a one-way trust decision for this host until the user
/// explicitly forgets the pin elsewhere; there is no "reject" button here
/// because declining simply means not tapping Approve and not retrying.
struct CertApprovalView: View {
    let info: CertInfo
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verify this server").font(.headline)
            Text("This is the first time connecting to this host. Compare the fingerprint below to the one shown in DSM before approving.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Subject", value: info.subject)
                .accessibilityIdentifier("login.cert.subject")
            LabeledContent("SHA-256", value: info.sha256Hex)
                .font(.system(.callout, design: .monospaced))
                .accessibilityIdentifier("login.cert.fingerprint")
            Button("Approve", action: onApprove)
                .accessibilityIdentifier("login.cert.approve")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("login.cert.approvalbanner")
    }
}
