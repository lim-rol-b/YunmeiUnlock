import SwiftUI
import CoreBluetooth

// MARK: - BLE 解锁管理器
final class BLEUnlockManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum UnlockError: LocalizedError {
        case bluetoothUnavailable
        case bluetoothUnauthorized
        case notConfigured
        case timeout(String)
        case serviceNotFound
        case characteristicNotFound
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable: return "蓝牙不可用（请打开蓝牙）"
            case .bluetoothUnauthorized: return "蓝牙未授权（请在系统设置允许）"
            case .notConfigured: return "尚未登录并配置门锁"
            case .timeout(let msg): return "超时：\(msg)"
            case .serviceNotFound: return "未找到目标服务 UUID"
            case .characteristicNotFound: return "未找到目标特征 UUID"
            case .writeFailed(let msg): return "写入失败：\(msg)"
            }
        }
    }

    // 超时（秒）
    private let foregroundScanTimeout: TimeInterval = 8
    private let backgroundScanTimeout: TimeInterval = 25
    private let connectTimeout: TimeInterval = 6
    private let discoverTimeout: TimeInterval = 6
    private let writeTimeout: TimeInterval = 4
    private let configuration: DoorConfiguration

    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var continuation: CheckedContinuation<Void, Error>?
    private var scanTimeout: TimeInterval = 8
    private var prefersCachedPeripheral = false
    private var didTryCachedPeripheral = false

    private var scanTimer: Timer?
    private var connectTimer: Timer?
    private var discoverTimer: Timer?
    private var writeTimer: Timer?

    // 同步日志闭包（UI 端自己 Dispatch 到主线程）
    var log: ((String) -> Void)?

    init(configuration: DoorConfiguration) {
        self.configuration = configuration
        super.init()
    }

    private var cachedPeripheralIdentifierKey: String {
        "cachedDoorPeripheralIdentifier.\(configuration.id)"
    }

    // Based on UnlockService.getPwd from yunmei_unintelligent (MIT License).
    // Copyright (c) 2022 zxypp.
    private func makeUnlockPayload(secret: String) -> Data {
        var payload: [UInt8] = []
        var pw = Int.random(in: 0...999_999)

        payload.append(208) // 0xD0
        let secretBytes = Array(secret.utf8)
        payload.append(UInt8(secretBytes.count + 14)) // len = secret.length + 14
        payload.append(contentsOf: secretBytes)
        payload.append(165) // 0xA5

        for _ in 0..<6 {
            payload.append(UInt8(pw % 10))
            pw /= 10
        }

        payload.append(contentsOf: [73, 68, 48, 49, 167]) // 'I''D''0''1' + 0xA7
        return Data(payload)
    }

    private func updateLiveActivity(phase: UnlockActivityAttributes.Phase, message: String) {
        guard #available(iOS 16.1, *) else { return }
        Task { await UnlockLiveActivityController.shared.update(phase: phase, message: message) }
    }

    private func endLiveActivity(success: Bool, message: String) {
        guard #available(iOS 16.1, *) else { return }
        Task { await UnlockLiveActivityController.shared.end(success: success, message: message) }
    }

    @MainActor
    func unlock(showsLiveActivity: Bool = true, prefersCachedPeripheral: Bool = false) async throws {
        self.prefersCachedPeripheral = prefersCachedPeripheral
        self.scanTimeout = showsLiveActivity ? foregroundScanTimeout : backgroundScanTimeout
        self.didTryCachedPeripheral = false

        if showsLiveActivity, #available(iOS 16.1, *) {
            await UnlockLiveActivityController.shared.start()
            await UnlockLiveActivityController.shared.update(phase: .preparing, message: "准备连接门锁")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            log?("初始化 CBCentralManager")
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let connectedPeripheral = retrieveConnectedPeripheral() {
                log?("发现系统已连接的门锁：\(connectedPeripheral.identifier)，直接使用")
                updateLiveActivity(phase: .connecting, message: "正在使用已连接的门锁")
                connect(to: connectedPeripheral)
                return
            }

            if prefersCachedPeripheral, let cachedPeripheral = retrieveCachedPeripheral() {
                didTryCachedPeripheral = true
                log?("找到缓存门锁设备：\(cachedPeripheral.identifier)，尝试直接连接")
                updateLiveActivity(phase: .connecting, message: "正在连接已记录的门锁")
                connect(to: cachedPeripheral)
                return
            }

            beginScanning()

        case .unauthorized:
            endLiveActivity(success: false, message: UnlockError.bluetoothUnauthorized.localizedDescription)
            finish(.failure(UnlockError.bluetoothUnauthorized))

        case .unsupported, .poweredOff, .resetting, .unknown:
            endLiveActivity(success: false, message: UnlockError.bluetoothUnavailable.localizedDescription)
            finish(.failure(UnlockError.bluetoothUnavailable))

        @unknown default:
            endLiveActivity(success: false, message: UnlockError.bluetoothUnavailable.localizedDescription)
            finish(.failure(UnlockError.bluetoothUnavailable))
        }
    }

    private func beginScanning() {
        let serviceUUID = CBUUID(string: configuration.serviceUUID)
        log?("蓝牙已开启，开始扫描服务：\(serviceUUID)，超时 \(Int(scanTimeout)) 秒")
        updateLiveActivity(phase: .scanning, message: "正在扫描门锁")
        central.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        startScanTimeout()
    }

    private func retrieveConnectedPeripheral() -> CBPeripheral? {
        let serviceUUID = CBUUID(string: configuration.serviceUUID)
        return central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first
    }

    private func retrieveCachedPeripheral() -> CBPeripheral? {
        guard let identifierString = UserDefaults.standard.string(forKey: cachedPeripheralIdentifierKey),
              let identifier = UUID(uuidString: identifierString) else {
            return nil
        }

        return central.retrievePeripherals(withIdentifiers: [identifier]).first
    }

    private func connect(to peripheral: CBPeripheral) {
        targetPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        startConnectTimeout()
    }

    private func cachePeripheralIdentifier(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: cachedPeripheralIdentifierKey)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        stopScanTimeout()
        central.stopScan()
        cachePeripheralIdentifier(peripheral)

        log?("发现设备：\(peripheral.name ?? "(no name)") rssi=\(RSSI)，准备连接")
        updateLiveActivity(phase: .connecting, message: "已发现门锁，正在连接")
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopConnectTimeout()
        cachePeripheralIdentifier(peripheral)
        log?("连接成功，开始发现服务")
        updateLiveActivity(phase: .discovering, message: "正在发现服务和特征")
        let serviceUUID = CBUUID(string: configuration.serviceUUID)
        peripheral.discoverServices([serviceUUID])
        startDiscoverTimeout()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        stopConnectTimeout()

        if didTryCachedPeripheral {
            didTryCachedPeripheral = false
            log?("缓存门锁连接失败，改为重新扫描")
            beginScanning()
            return
        }

        endLiveActivity(success: false, message: error?.localizedDescription ?? UnlockError.timeout("连接失败").localizedDescription)
        finish(.failure(error ?? UnlockError.timeout("连接失败")))
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            stopDiscoverTimeout()
            endLiveActivity(success: false, message: error.localizedDescription)
            finish(.failure(error))
            return
        }

        let serviceUUID = CBUUID(string: configuration.serviceUUID)
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            stopDiscoverTimeout()
            endLiveActivity(success: false, message: UnlockError.serviceNotFound.localizedDescription)
            finish(.failure(UnlockError.serviceNotFound))
            return
        }

        log?("发现目标服务，开始发现特征")
        let charUUID = CBUUID(string: configuration.characteristicUUID)
        peripheral.discoverCharacteristics([charUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        stopDiscoverTimeout()

        if let error = error {
            endLiveActivity(success: false, message: error.localizedDescription)
            finish(.failure(error))
            return
        }

        let charUUID = CBUUID(string: configuration.characteristicUUID)
        guard let ch = service.characteristics?.first(where: { $0.uuid == charUUID }) else {
            endLiveActivity(success: false, message: UnlockError.characteristicNotFound.localizedDescription)
            finish(.failure(UnlockError.characteristicNotFound))
            return
        }

        let payload = makeUnlockPayload(secret: configuration.secret)
        log?("写入开门 payload（\(payload.count) bytes）")
        updateLiveActivity(phase: .writing, message: "正在发送开门指令")
        peripheral.writeValue(payload, for: ch, type: .withResponse)
        startWriteTimeout()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        stopWriteTimeout()

        if let error = error {
            endLiveActivity(success: false, message: UnlockError.writeFailed(error.localizedDescription).localizedDescription)
            finish(.failure(UnlockError.writeFailed(error.localizedDescription)))
            return
        }

        log?("写入成功，断开连接")
        endLiveActivity(success: true, message: "开门指令已发送")
        finish(.success(()))
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Timeout helpers

    private func startScanTimeout() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanTimeout, repeats: false) { [weak self] _ in
            self?.endLiveActivity(success: false, message: UnlockError.timeout("扫描不到门锁，请靠近后重试").localizedDescription)
            self?.finish(.failure(UnlockError.timeout("扫描不到门锁，请靠近后重试")))
        }
    }
    private func stopScanTimeout() { scanTimer?.invalidate(); scanTimer = nil }

    private func startConnectTimeout() {
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: connectTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }

            if didTryCachedPeripheral {
                didTryCachedPeripheral = false
                if let targetPeripheral {
                    central.cancelPeripheralConnection(targetPeripheral)
                }
                log?("缓存门锁连接超时，改为重新扫描")
                beginScanning()
                return
            }

            endLiveActivity(success: false, message: UnlockError.timeout("连接超时").localizedDescription)
            finish(.failure(UnlockError.timeout("连接超时")))
        }
    }
    private func stopConnectTimeout() { connectTimer?.invalidate(); connectTimer = nil }

    private func startDiscoverTimeout() {
        discoverTimer?.invalidate()
        discoverTimer = Timer.scheduledTimer(withTimeInterval: discoverTimeout, repeats: false) { [weak self] _ in
            self?.endLiveActivity(success: false, message: UnlockError.timeout("发现服务/特征超时").localizedDescription)
            self?.finish(.failure(UnlockError.timeout("发现服务/特征超时")))
        }
    }
    private func stopDiscoverTimeout() { discoverTimer?.invalidate(); discoverTimer = nil }

    private func startWriteTimeout() {
        writeTimer?.invalidate()
        writeTimer = Timer.scheduledTimer(withTimeInterval: writeTimeout, repeats: false) { [weak self] _ in
            self?.endLiveActivity(success: false, message: UnlockError.timeout("写入超时").localizedDescription)
            self?.finish(.failure(UnlockError.timeout("写入超时")))
        }
    }
    private func stopWriteTimeout() { writeTimer?.invalidate(); writeTimer = nil }

    // MARK: - Finish

    private func finish(_ result: Result<Void, Error>) {
        stopScanTimeout()
        stopConnectTimeout()
        stopDiscoverTimeout()
        stopWriteTimeout()

        guard let cont = continuation else { return }
        continuation = nil

        if central != nil { central.stopScan() }

        switch result {
        case .success:
            cont.resume()
        case .failure(let err):
            cont.resume(throwing: err)
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @EnvironmentObject private var configurationStore: DoorConfigurationStore

    var body: some View {
        Group {
            if let configuration = configurationStore.activeConfiguration {
                UnlockHomeView(configuration: configuration)
                    .id(configuration.id)
            } else {
                LoginView()
            }
        }
    }
}

private struct UnlockHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var configurationStore: DoorConfigurationStore

    let configuration: DoorConfiguration

    @State private var status = "准备就绪"
    @State private var logs: [String] = []
    @State private var isShowingConfiguration = false
    @State private var isShowingClearConfirmation = false

    // 防抖：N 秒内只自动触发一次（避免反复切前后台）
    private let autoUnlockCooldown: TimeInterval = 25
    @State private var lastAutoUnlockAt: Date? = nil

    // 防止同一时刻重复并发开门
    @State private var isUnlocking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(configuration.name)
                    .font(.title2.bold())

                if configurationStore.configurations.count > 1 {
                    Picker("当前门锁", selection: activeDoorBinding) {
                        ForEach(configurationStore.configurations) { door in
                            Text(door.name).tag(door.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Text(status).font(.headline)

                Button {
                    Task { await unlock(manual: true) }
                } label: {
                    Text(isUnlocking ? "开门中…" : "手动测试开门")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .foregroundColor(.white)
                        .background(isUnlocking ? Color.gray : Color.blue)
                        .cornerRadius(10)
                }
                .disabled(isUnlocking)

                Text("自动开门：当 App 进入前台时触发（冷却 \(Int(autoUnlockCooldown)) 秒）")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                List(logs, id: \.self) { line in
                    Text(line).font(.footnote)
                }
            }
            .padding()
            .navigationTitle("云莓门禁")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("重新登录并配置") {
                            isShowingConfiguration = true
                        }
                        Button("清除门禁配置", role: .destructive) {
                            isShowingClearConfirmation = true
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $isShowingConfiguration) {
                LoginView { isShowingConfiguration = false }
                    .environmentObject(configurationStore)
            }
            .alert("清除门禁配置？", isPresented: $isShowingClearConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    do {
                        try configurationStore.clear()
                    } catch {
                        status = "❌ 清除失败：\(error.localizedDescription)"
                    }
                }
            } message: {
                Text("已保存的门锁密钥将从本机 Keychain 删除，之后需要重新登录。")
            }
            .onAppear {
                Task { await unlockIfAllowed(reason: "onAppear") }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await unlockIfAllowed(reason: "scenePhase.active") }
                }
            }
        }
    }

    private var activeDoorBinding: Binding<String> {
        Binding(
            get: { configuration.id },
            set: { id in
                guard let door = configurationStore.configurations.first(where: { $0.id == id }) else { return }
                do {
                    try configurationStore.select(door)
                } catch {
                    status = "❌ 切换门锁失败：\(error.localizedDescription)"
                }
            }
        )
    }

    private func unlockIfAllowed(reason: String) async {
        // 冷却判断
        if let last = lastAutoUnlockAt, Date().timeIntervalSince(last) < autoUnlockCooldown {
            appendLog("自动开门跳过（冷却中）：\(reason)")
            return
        }
        await unlock(manual: false)
    }

    @MainActor
    private func appendLog(_ s: String) {
        logs.append(s)
    }

    private func unlock(manual: Bool) async {
        // 并发保护
        if isUnlocking {
            appendLog("忽略：已在开门流程中")
            return
        }

        await MainActor.run {
            isUnlocking = true
            status = manual ? "手动开门中…" : "自动开门中…"
            if manual { logs.removeAll() } // 手动时清屏更直观
        }

        let mgr = BLEUnlockManager(configuration: configuration)
        mgr.log = { msg in
            DispatchQueue.main.async {
                logs.append(msg)
            }
        }

        do {
            try await mgr.unlock()
            await MainActor.run {
                status = "✅ 已发送开门指令（写入成功）"
                if !manual { lastAutoUnlockAt = Date() }
                isUnlocking = false
            }
        } catch {
            await MainActor.run {
                status = "❌ 开门失败：\(error.localizedDescription)"
                if !manual { lastAutoUnlockAt = Date() } // 失败也进入冷却，避免疯狂重试
                isUnlocking = false
            }
        }
    }
}
