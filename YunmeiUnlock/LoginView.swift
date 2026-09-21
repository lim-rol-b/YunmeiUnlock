import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var configurationStore: DoorConfigurationStore

    var onSaved: (() -> Void)?

    @State private var username = ""
    @State private var password = ""
    @State private var loginContext: YunmeiLoginContext?
    @State private var selectedSchoolID = ""
    @State private var doors: [DoorConfiguration] = []
    @State private var selectedDoorID = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let api = YunmeiAPIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("云莓智能账号", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("登录")
                } footer: {
                    Text("账号和密码仅用于向云莓智能官方服务登录；密码不会保存在本机。")
                }

                if let context = loginContext {
                    Section("选择学校") {
                        Picker("学校", selection: schoolSelection) {
                            ForEach(context.schools) { school in
                                Text(school.name).tag(school.id)
                            }
                        }

                        Button("获取门锁") {
                            Task { await loadDoors() }
                        }
                        .disabled(isLoading || selectedSchoolID.isEmpty)
                    }
                }

                if !doors.isEmpty {
                    Section("选择默认门锁") {
                        Picker("门锁", selection: $selectedDoorID) {
                            ForEach(doors) { door in
                                Text(door.name).tag(door.id)
                            }
                        }

                        Button("保存门禁配置") {
                            saveConfiguration()
                        }
                        .disabled(selectedDoorID.isEmpty)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                if loginContext == nil {
                    Section {
                        Button {
                            Task { await login() }
                        } label: {
                            HStack {
                                Spacer()
                                if isLoading { ProgressView() }
                                Text(isLoading ? "正在登录…" : "登录")
                                Spacer()
                            }
                        }
                        .disabled(isLoading || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    }
                }
            }
            .navigationTitle("配置云莓门禁")
        }
    }

    private var schoolSelection: Binding<String> {
        Binding(
            get: { selectedSchoolID },
            set: { id in
                selectedSchoolID = id
                doors = []
                selectedDoorID = ""
                errorMessage = nil
            }
        )
    }

    @MainActor
    private func login() async {
        isLoading = true
        errorMessage = nil
        doors = []
        selectedDoorID = ""
        defer { isLoading = false }

        do {
            let context = try await api.login(username: username, password: password)
            loginContext = context
            selectedSchoolID = context.schools[0].id
            password = ""
            if context.schools.count == 1 {
                await loadDoors()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadDoors() async {
        guard let context = loginContext,
              let school = context.schools.first(where: { $0.id == selectedSchoolID }) else {
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            doors = try await api.doors(for: school, userID: context.userID)
            selectedDoorID = doors[0].id
        } catch {
            doors = []
            selectedDoorID = ""
            errorMessage = error.localizedDescription
        }
    }

    private func saveConfiguration() {
        do {
            try configurationStore.replace(with: doors, activeID: selectedDoorID)
            onSaved?()
        } catch {
            errorMessage = "保存门禁配置失败：\(error.localizedDescription)"
        }
    }
}
