//
// Copyright © 2026 Turing Software, LLC. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import AppKit
import QEMUKit
#if !WITH_USB
import CocoaSpiceNoUsb
#else
import CocoaSpice
#endif

/// Text clipboard sharing with a Mac OS X guest through VirtualIntelMac 2.2's guest helpers:
/// Intel (Snow Leopard … High Sierra, helpers on the COM ports; Mojave and later on a VirtIO
/// console port) and PowerPC Tiger/Leopard (UTM's PowerPC build of the helpers, on PCI serial
/// ports), installed by the guest kits.
///
/// Port of VirtualIntelMac's VIMClipboardBridge and the provisioning in VIMSession (MIT):
/// - The guest's root agent (`opengl-guest-agent`, QGA protocol on COM2) runs
///   `guest-clipboard --provision-stdin` with a fresh token once a user is logged in. The
///   helper then starts a job in that user's session, which opens its serial port.
/// - That port reaches UTM as the `org.vim.clipboard` SPICE port and carries newline-delimited
///   JSON, protocol 2: the helper authenticates with the token (`hello`), then both sides
///   exchange `text` messages; `ping`/`pong` detect a helper that went away.
/// Host text goes to the guest only while UTM is the active app, as in VirtualIntelMac.
///
/// With `isDisplayPowerOnly` the same helper runs as VirtualIntelMac's display power observer
/// (Mojave and later, `org.vim.display`): it needs no logged-in user and only reports
/// `display-power` changes, because the donated framebuffer drivers don't tell the host.
@MainActor
final class UTMIntelMacClipboard: NSObject {
    private static let helperPath = "/Library/Application Support/Virtual Intel Mac/GuestTools/guest-clipboard"
    private static let maxText = 1024 * 1024
    private static let maxWire = 8 * 1024 * 1024

    private weak var vm: UTMQemuVirtualMachine?
    private weak var ioService: UTMSpiceIO?
    private var timer: Timer?
    private var portObservation: NSKeyValueObservation?
    private weak var port: CSPort?

    private var token: String?
    private var consoleUID: Int?
    private var isProvisioning = false
    private var retryAfter = Date.distantPast
    private var handshakeDeadline: Date?

    private var isAuthenticated = false
    private var incoming = Data()
    private var change = 0
    private var sent = 0
    private var received = 0
    private var heartbeat = 0
    private var awaitingHeartbeat = 0
    private var lastHeartbeat: TimeInterval = 0
    private var heartbeatDeadline: TimeInterval = 0
    private var pendingChange = 0
    private var pendingNextRead: TimeInterval = 0
    private var pendingDelay: TimeInterval = 0

    /// Transport the guest helper expects (VirtualIntelMac's `Transport`): VirtIO console on
    /// Mojave and later, serial port on older guests.
    private let transport: String
    /// A VirtIO console port reaches UTM only once the guest opens it, i.e. after the helper
    /// starts; a serial port is always there. Provisioning can't wait for a VirtIO port.
    private var isPortReady: Bool {
        port != nil || transport == "virtio-serial"
    }

    private let isDisplayPowerOnly: Bool
    /// Called with `true` when the guest display sleeps and `false` when it wakes or the
    /// observer is lost (never leave the window dark on a stale state).
    private let displayPowerChanged: ((Bool) -> Void)?
    private var isGuestDisplaySleeping = false

    init(vm: UTMQemuVirtualMachine, ioService: UTMSpiceIO, isVirtio: Bool, isDisplayPowerOnly: Bool = false, displayPowerChanged: ((Bool) -> Void)? = nil) {
        self.vm = vm
        self.ioService = ioService
        self.transport = isVirtio ? "virtio-serial" : "isa-serial"
        self.isDisplayPowerOnly = isDisplayPowerOnly
        self.displayPowerChanged = displayPowerChanged
    }

    func start() {
        if isDisplayPowerOnly {
            portObservation = ioService?.observe(\.vimDisplayPort, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.attachPort() }
            }
        } else {
            portObservation = ioService?.observe(\.vimClipboardPort, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.attachPort() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: isDisplayPowerOnly ? 1 : 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        if isAuthenticated {
            port?.write(Data("{\"type\":\"stop\"}\n".utf8))
        }
        timer?.invalidate()
        timer = nil
        portObservation = nil
        resetConnection()
        token = nil
        port?.delegate = nil
        port = nil
    }

    private func attachPort() {
        let newPort = isDisplayPowerOnly ? ioService?.vimDisplayPort : ioService?.vimClipboardPort
        guard newPort !== port else {
            return
        }
        // A VirtIO port opens and closes with the guest's use of it: provisioning itself opens and
        // closes it once (to set its owner) before the helper opens it for good. Until the helper
        // says hello, keep the token it was provisioned with.
        let isAwaitingHello = transport == "virtio-serial" && !isAuthenticated && token != nil
        let deadline = handshakeDeadline
        port?.delegate = nil
        resetConnection()
        if isAwaitingHello {
            handshakeDeadline = newPort != nil ? Date(timeIntervalSinceNow: 30) : deadline
        } else {
            token = nil
        }
        port = newPort
        port?.delegate = self
    }

    private func resetConnection() {
        if isGuestDisplaySleeping {
            isGuestDisplaySleeping = false
            displayPowerChanged?(false)
        }
        isAuthenticated = false
        incoming = Data()
        sent = 0
        received = 0
        heartbeat = 0
        awaitingHeartbeat = 0
        handshakeDeadline = nil
        pendingDelay = 0
    }

    /// Lost helper or protocol error: provision again after a pause, as VirtualIntelMac does.
    private func fail(line: Int = #line) {
        logger.warning("Intel Mac clipboard\(isDisplayPowerOnly ? " (display power)" : ""): connection reset (\(transport), UTMIntelMacClipboard.swift:\(line))")
        resetConnection()
        token = nil
        retryAfter = Date(timeIntervalSinceNow: 60)
    }

    // MARK: - Provisioning

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        if isAuthenticated {
            exchange()
            return
        }
        if let deadline = handshakeDeadline, deadline.timeIntervalSinceNow < 0 {
            logger.warning("Intel Mac clipboard: guest helper did not connect")
            fail()
            return
        }
        // look for a logged-in user every 5 s until the helper connects
        if isPortReady && token == nil && !isProvisioning && retryAfter.timeIntervalSinceNow < 0 && tickCount % (isDisplayPowerOnly ? 5 : 25) == 0 {
            Task { await provision() }
        }
    }

    private func run(_ agent: QEMUGuestAgent, _ path: String, _ arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> (Int, Data?) {
        let pid = try await agent.guestExec(path, argv: arguments, envp: nil, input: input, captureOutput: true)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while deadline.timeIntervalSinceNow > 0 {
            let status = try await agent.guestExecStatus(pid)
            if status.hasExited {
                return (status.exitCode, status.outData)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CancellationError()
    }

    private func provision() async {
        guard let vm = vm, let agent = await vm.guestAgent else {
            return
        }
        isProvisioning = true
        defer { isProvisioning = false }
        do {
            // Re-align the agent channel first, as VirtualIntelMac does: after a guest restart
            // (PowerPC resets in the same QEMU process) or an agent reload, a reply to a request
            // that timed out can still arrive and be taken for the answer to the next one.
            try await agent.synchronize()
            let uid: Int
            if isDisplayPowerOnly {
                uid = 0 // the observer runs under a fixed system account, logged in or not
            } else {
                // VirtualIntelMac learns the console user the same way
                let (status, output) = try await run(agent, "/usr/bin/stat", ["-f", "%u", "/dev/console"], timeout: 15)
                guard status == 0, let text = output.flatMap({ String(data: $0, encoding: .utf8) }),
                      let consoleUser = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), consoleUser >= 501 else {
                    return // nobody logged in yet
                }
                uid = consoleUser
            }
            guard isPortReady, token == nil else {
                return
            }
            let newToken = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            let configuration: [String: Any] = ["UID": uid, "Transport": transport, "Token": newToken, "DisplayPowerOnly": isDisplayPowerOnly]
            let input = try JSONSerialization.data(withJSONObject: configuration)
            token = newToken
            consoleUID = uid
            let result: Int
            if transport == "virtio-serial" {
                result = try await provisionFromFile(agent, configuration: input)
            } else {
                result = try await run(agent, Self.helperPath, ["--provision-stdin"], input: input, timeout: 120).0
            }
            guard token == newToken else {
                return
            }
            if result == 0 {
                handshakeDeadline = Date(timeIntervalSinceNow: 30)
            } else {
                logger.warning("Intel Mac clipboard: guest helper setup exited with \(result)")
                fail()
            }
        } catch {
            logger.warning("Intel Mac clipboard: guest agent: \(error.localizedDescription)")
            if token != nil && !isAuthenticated {
                fail()
            }
        }
    }

    /// VirtualIntelMac's helper for Mojave and later only takes `--provision <file>`: as VirtualIntelMac
    /// does, write the configuration through the agent to a private file (root, 0600) and pass its path.
    private func provisionFromFile(_ agent: QEMUGuestAgent, configuration: Data) async throws -> Int {
        let (status, output) = try await run(agent, "/usr/bin/mktemp", ["-d", "/private/var/tmp/utm-clipboard.XXXXXX"], timeout: 15)
        guard status == 0, let directory = output.flatMap({ String(data: $0, encoding: .utf8) })?
                .trimmingCharacters(in: .whitespacesAndNewlines), directory.hasPrefix("/private/var/tmp/utm-clipboard.") else {
            return status == 0 ? 74 : status
        }
        defer {
            Task { _ = try? await run(agent, "/bin/rm", ["-rf", directory], timeout: 15) }
        }
        let path = directory + "/config.json"
        let handle = try await agent.guestFileOpen(path, mode: "w")
        do {
            _ = try await agent.guestFileWrite(handle, data: configuration)
        } catch {
            try? await agent.guestFileClose(handle)
            throw error
        }
        try await agent.guestFileClose(handle)
        // guest-file-open follows the agent's umask; the helper only reads a private file
        let (mode, _) = try await run(agent, "/bin/chmod", ["0600", path], timeout: 15)
        guard mode == 0 else {
            return mode
        }
        return try await run(agent, Self.helperPath, ["--provision", path], timeout: 60).0
    }

    // MARK: - Protocol

    private var isExchangeAllowed: Bool {
        NSApp.isActive
    }

    private func send(_ message: [String: Any]) {
        guard let port = port, var data = try? JSONSerialization.data(withJSONObject: message), data.count < Self.maxWire else {
            fail()
            return
        }
        data.append(UInt8(ascii: "\n"))
        port.write(data)
    }

    private func receive(_ message: [String: Any]) {
        let type = message["type"] as? String
        if !isAuthenticated {
            guard type == "hello", (message["protocol"] as? NSNumber)?.intValue == 2,
                  let token = token, message["token"] as? String == token else {
                fail()
                return
            }
            isAuthenticated = true
            handshakeDeadline = nil
            if !isDisplayPowerOnly {
                change = NSPasteboard.general.changeCount
            }
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            send(["type": "ready", "protocol": 2])
            logger.info("Intel Mac clipboard\(isDisplayPowerOnly ? " (display power)" : ""): connected")
            return
        }
        if type == "pong" {
            guard awaitingHeartbeat != 0, (message["sequence"] as? NSNumber)?.intValue == awaitingHeartbeat else {
                fail()
                return
            }
            awaitingHeartbeat = 0
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            return
        }
        if isDisplayPowerOnly {
            guard type == "display-power", let sleeping = message["sleeping"] as? NSNumber,
                  CFGetTypeID(sleeping as CFTypeRef) == CFBooleanGetTypeID() else {
                fail()
                return
            }
            if isGuestDisplaySleeping != sleeping.boolValue {
                isGuestDisplaySleeping = sleeping.boolValue
                displayPowerChanged?(isGuestDisplaySleeping)
            }
            return
        }
        guard type == "text", let sequence = (message["sequence"] as? NSNumber)?.intValue,
              let text = message["text"] as? String, sequence > received,
              text.utf8.count <= Self.maxText else {
            fail()
            return
        }
        received = sequence
        guard isExchangeAllowed else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        change = pasteboard.changeCount
    }

    private func exchange() {
        let now = ProcessInfo.processInfo.systemUptime
        // QEMU keeps the serial port open after the guest's helper exits
        if awaitingHeartbeat != 0 {
            if now >= heartbeatDeadline {
                fail()
                return
            }
        } else if now - lastHeartbeat >= 5 {
            heartbeat += 1
            awaitingHeartbeat = heartbeat
            heartbeatDeadline = now + 30
            send(["type": "ping", "sequence": heartbeat])
        }
        guard !isDisplayPowerOnly, isExchangeAllowed else {
            return
        }
        let pasteboard = NSPasteboard.general
        let newChange = pasteboard.changeCount
        guard newChange != change else {
            return
        }
        // an owner may announce a change before it supplies the text: retry with backoff
        if pendingDelay == 0 || pendingChange != newChange {
            pendingChange = newChange
            pendingNextRead = 0
            pendingDelay = 0.2
        }
        guard now >= pendingNextRead else {
            return
        }
        guard let text = pasteboard.string(forType: .string) else {
            if let types = pasteboard.types, !types.isEmpty, pasteboard.availableType(from: [.string]) == nil {
                change = newChange // not text: nothing to share
                pendingDelay = 0
            } else {
                pendingNextRead = now + pendingDelay
                pendingDelay = min(1, pendingDelay * 2)
            }
            return
        }
        change = newChange
        pendingDelay = 0
        if text.utf8.count <= Self.maxText {
            sent += 1
            send(["type": "text", "sequence": sent, "text": text])
        }
    }
}

extension UTMIntelMacClipboard: CSPortDelegate {
    nonisolated func portDidDisconect(_ port: CSPort) {
        Task { @MainActor in
            // A VirtIO port closes whenever the guest closes the device, e.g. while provisioning
            // sets its owner; attachPort handles that close and the reopen.
            if port === self.port && self.transport != "virtio-serial" {
                self.fail()
            }
        }
    }

    nonisolated func port(_ port: CSPort, didError error: String) {
        Task { @MainActor in
            if port === self.port {
                logger.warning("Intel Mac clipboard: port error \(error)")
                self.fail()
            }
        }
    }

    nonisolated func port(_ port: CSPort, didRecieveData data: Data) {
        Task { @MainActor in
            guard port === self.port else {
                return
            }
            self.incoming.append(data)
            if self.incoming.count > Self.maxWire {
                self.fail()
                return
            }
            while let newline = self.incoming.firstIndex(of: UInt8(ascii: "\n")) {
                let line = self.incoming[self.incoming.startIndex..<newline]
                self.incoming.removeSubrange(self.incoming.startIndex...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    self.fail()
                    return
                }
                self.receive(message)
            }
        }
    }
}
