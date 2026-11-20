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

/// Text clipboard sharing with a Mac OS X Intel guest (Snow Leopard … High Sierra) through
/// VirtualIntelMac 2.2's guest helpers, installed by the Intel guest kit.
///
/// Port of VirtualIntelMac's VIMClipboardBridge and the provisioning in VIMSession (MIT):
/// - The guest's root agent (`opengl-guest-agent`, QGA protocol on COM2) runs
///   `guest-clipboard --provision-stdin` with a fresh token once a user is logged in. The
///   helper then starts a job in that user's session, which opens COM1.
/// - COM1 reaches UTM as the `org.vim.clipboard` SPICE port and carries newline-delimited
///   JSON, protocol 2: the helper authenticates with the token (`hello`), then both sides
///   exchange `text` messages; `ping`/`pong` detect a helper that went away.
/// Host text goes to the guest only while UTM is the active app, as in VirtualIntelMac.
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

    init(vm: UTMQemuVirtualMachine, ioService: UTMSpiceIO) {
        self.vm = vm
        self.ioService = ioService
    }

    func start() {
        portObservation = ioService?.observe(\.vimClipboardPort, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.attachPort() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        if isAuthenticated {
            port?.writeData(Data("{\"type\":\"stop\"}\n".utf8))
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
        let newPort = ioService?.vimClipboardPort
        guard newPort !== port else {
            return
        }
        port?.delegate = nil
        resetConnection()
        token = nil
        port = newPort
        port?.delegate = self
    }

    private func resetConnection() {
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
    private func fail() {
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
            logger.debug("Intel Mac clipboard: guest helper did not connect")
            fail()
            return
        }
        // look for a logged-in user every 5 s until the helper connects
        if port != nil && token == nil && !isProvisioning && retryAfter.timeIntervalSinceNow < 0 && tickCount % 25 == 0 {
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
            // VirtualIntelMac learns the console user the same way
            let (status, output) = try await run(agent, "/usr/bin/stat", ["-f", "%u", "/dev/console"], timeout: 15)
            guard status == 0, let text = output.flatMap({ String(data: $0, encoding: .utf8) }),
                  let uid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), uid >= 501 else {
                return // nobody logged in yet
            }
            guard port != nil, token == nil else {
                return
            }
            let newToken = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            let configuration: [String: Any] = ["UID": uid, "Transport": "isa-serial", "Token": newToken, "DisplayPowerOnly": false]
            let input = try JSONSerialization.data(withJSONObject: configuration)
            token = newToken
            consoleUID = uid
            let (result, _) = try await run(agent, Self.helperPath, ["--provision-stdin"], input: input, timeout: 120)
            guard token == newToken else {
                return
            }
            if result == 0 {
                handshakeDeadline = Date(timeIntervalSinceNow: 30)
            } else {
                logger.debug("Intel Mac clipboard: guest helper setup exited with \(result)")
                fail()
            }
        } catch {
            logger.debug("Intel Mac clipboard: guest agent: \(error.localizedDescription)")
            if token != nil && !isAuthenticated {
                fail()
            }
        }
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
        port.writeData(data)
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
            change = NSPasteboard.general.changeCount
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            send(["type": "ready", "protocol": 2])
            logger.debug("Intel Mac clipboard: connected")
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
        guard isExchangeAllowed else {
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
            if port === self.port {
                self.fail()
            }
        }
    }

    nonisolated func port(_ port: CSPort, didError error: String) {
        Task { @MainActor in
            if port === self.port {
                logger.debug("Intel Mac clipboard: port error \(error)")
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
