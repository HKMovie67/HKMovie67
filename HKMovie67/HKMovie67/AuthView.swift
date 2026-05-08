//
//  AuthView.swift
//  HKMovie67
//

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("selectedLanguage") private var lang: AppLanguage = .traditional

    @State private var isRegister = false
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showResetAlert = false
    @State private var localError: String? = nil
    
    private let termsURL = URL(string: "https://hkmovie67.com/terms.html")!
    private let privacyURL = URL(string: "https://hkmovie67.com/privacy.html")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Logo / App Name
                    VStack(spacing: 8) {
                        Image(systemName: "popcorn.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)
                        Text("HKMovie 67")
                            .font(.largeTitle).bold()
                        Text(isRegister
                             ? lang.t("建立帳號", "建立帐号", "Create Account")
                             : lang.t("登入帳號", "登录帐号", "Sign In"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)

                    // Fields
                    VStack(spacing: 16) {
                        TextField(lang.t("電郵地址", "电邮地址", "Email Address"), text: $email)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .textContentType(.emailAddress)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)

                        SecureField(lang.promptPasswordPlaceholder, text: $password)
                            .textContentType(isRegister ? .newPassword : .password)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)

                        if isRegister {
                            SecureField(
                                lang.t("確認密碼", "确认密码", "Confirm Password"),
                                text: $confirmPassword
                            )
                            .textContentType(.newPassword)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                    }

                    // Error
                    if let err = auth.errorMessage ?? localError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Primary Buttons
                    VStack(spacing: 16) {
                        // Email Sign In/Register Button
                        Button {
                            Task { await submit() }
                        } label: {
                            Group {
                                if auth.isLoading {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                } else {
                                    Text(isRegister
                                         ? lang.t("建立帳號", "建立帐号", "Create Account")
                                         : lang.t("登入", "登录", "Sign In"))
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(auth.isLoading)
                        
                        // Sign in with Apple Button
                        SignInWithAppleButton(
                            isRegister ? .signUp : .signIn,
                            onRequest: { request in
                                auth.prepareAppleRequest(request)
                            },
                            onCompletion: { result in
                                Task { await auth.handleAppleCompletion(result) }
                            }
                        )
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(auth.isLoading)
                        
                        // Google Sign In Button
                        Button {
                            Task {
                                await auth.signInWithGoogle()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "g.circle.fill")
                                    .font(.title2)
                                Text(lang.t("透過 Google 登入", "使用 Google 登录", "Sign in with Google"))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.white)
                            .foregroundColor(.black)
                            .cornerRadius(12)
                            .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
                        }
                        .disabled(auth.isLoading)
                    }

                    // Toggle Register / Sign In
                    Button {
                        withAnimation { isRegister.toggle() }
                        localError = nil
                    } label: {
                        Text(isRegister
                             ? lang.t("已有帳號？登入", "已有帐号？登录", "Already have an account? Sign In")
                             : lang.t("沒有帳號？立即建立", "没有帐号？立即建立", "No account? Create one"))
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }

                    // Forgot Password
                    if !isRegister {
                        Button {
                            showResetAlert = true
                        } label: {
                            Text(lang.t("忘記密碼？", "忘记密码？", "Forgot Password?"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    VStack(spacing: 6) {
                        Text(
                            isRegister
                            ? lang.t("建立帳號即表示你同意我們的", "建立帐号即表示你同意我们的", "By creating an account, you agree to our")
                            : lang.t("繼續登入即表示你同意我們的", "继续登录即表示你同意我们的", "By continuing, you agree to our")
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        
                        HStack(spacing: 8) {
                            Link(
                                lang.t("使用條款", "使用条款", "Terms of Service"),
                                destination: termsURL
                            )
                            .font(.caption2)
                            
                            Text("·")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Link(
                                lang.t("私隱政策", "隐私政策", "Privacy Policy"),
                                destination: privacyURL
                            )
                            .font(.caption2)
                        }
                    }
                    .padding(.top, 4)

                    Spacer()
                }
                .padding(.horizontal, 28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(lang.buttonCancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LanguageSwitcherView()
                }
            }
            .alert(lang.t("重設密碼", "重设密码", "Reset Password"), isPresented: $showResetAlert) {
                Button(lang.buttonCancel, role: .cancel) { }
                Button(lang.buttonSubmit) {
                    Task { await auth.resetPassword(email: email) }
                }
            } message: {
                Text(lang.t(
                    "將向 \(email) 發送重設密碼電郵。",
                    "将向 \(email) 发送重设密码邮件。",
                    "A password reset email will be sent to \(email)."
                ))
            }
            .onChange(of: auth.isSignedIn) { _, isSignedIn in
                if isSignedIn {
                    dismiss()
                }
            }
        }
    }

    private func submit() async {
        localError = nil
        if email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty {
            localError = lang.t("請填寫所有欄位。", "请填写所有字段。", "Please fill in all fields.")
            return
        }
        if isRegister {
            if password != confirmPassword {
                localError = lang.t("密碼不相符。", "密码不相符。", "Passwords do not match.")
                return
            }
            if password.count < 6 {
                localError = lang.t("密碼最少需6個字元。", "密码最少需6个字符。", "Password must be at least 6 characters.")
                return
            }
            await auth.register(email: email, password: password)
        } else {
            await auth.signIn(email: email, password: password)
        }
    }
}
