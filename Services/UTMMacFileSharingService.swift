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

import Foundation
import dnssd
import QEMUKit

/// Lists a Mac OS X guest's SMB File Sharing in Finder (Network) under the guest's computer name.
///
/// Port of VirtualIntelMac 2.2's VIMSMBService (MIT): QEMU forwards the guest's port 445 to a
/// local-only host port; this publishes a local-only DNS-SD `_smb._tcp` service with that port,
/// on a host name that resolves to 127.0.0.1. Nothing is advertised on the network.
/// It starts as "<VM name>-VM"; once the guest agent answers, the guest's own computer name
/// replaces it, so Finder shows one entry with the name set in the guest's Sharing preferences
/// (Finder merges a same-named service the guest itself may announce).
@MainActor
final class UTMMacFileSharingService {
    private var instance: String
    private let hostname: String
    private let port: UInt16
    private var addressConnection: DNSServiceRef?
    private var service: DNSServiceRef?
    private var deviceInfo: DNSServiceRef?
    /// The guest's Mac model (hw.model): Finder picks the entry's icon from it.
    private var model: String?

    private var nameTask: Task<Void, Never>?

    init(name: String, uuid: UUID, port: Int) {
        // a host-name-safe instance, like VirtualIntelMac's
        var instance = ""
        for scalar in name.unicodeScalars where instance.count < 26 {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                instance.unicodeScalars.append(scalar)
            } else if !instance.isEmpty && !instance.hasSuffix("-") {
                instance.append("-")
            }
        }
        if instance.hasSuffix("-") {
            instance.removeLast()
        }
        self.instance = (instance.isEmpty ? "VirtualMac" : instance) + "-VM"
        self.hostname = "utm-\(uuid.uuidString.lowercased()).local."
        self.port = UInt16(clamping: port)
    }

    func start() {
        unregister()
        let noError = DNSServiceErrorType(kDNSServiceErr_NoError)
        var loopback = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        var record: DNSRecordRef?
        var status = DNSServiceCreateConnection(&addressConnection)
        if status == noError, let connection = addressConnection {
            status = DNSServiceSetDispatchQueue(connection, .main)
        }
        if status == noError, let connection = addressConnection {
            status = DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique),
                                              UInt32.max /* kDNSServiceInterfaceIndexLocalOnly */, hostname,
                                              UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                              UInt16(MemoryLayout<in_addr>.size), &loopback, 120,
                                              { _, _, _, _, _ in }, nil)
        }
        if status == noError {
            // no automatic renaming: a name clash must not point at another VM
            status = DNSServiceRegister(&service, DNSServiceFlags(kDNSServiceFlagsNoAutoRename),
                                        UInt32.max /* kDNSServiceInterfaceIndexLocalOnly */, instance, "_smb._tcp.", "local.",
                                        hostname, port.bigEndian, 0, nil,
                                        { _, _, _, _, _, _, _ in }, nil)
        }
        if status == noError, let service = service {
            status = DNSServiceSetDispatchQueue(service, .main)
        }
        if status == noError, let model = model {
            // Finder's icon for the entry, as a real Mac announces it; the entry works without it
            let entry = Array(("model=" + model).utf8.prefix(255))
            let txt = Data([UInt8(entry.count)] + entry)
            var iconStatus = txt.withUnsafeBytes { bytes in
                DNSServiceRegister(&deviceInfo, DNSServiceFlags(kDNSServiceFlagsNoAutoRename),
                                   UInt32.max /* kDNSServiceInterfaceIndexLocalOnly */, instance, "_device-info._tcp.", "local.",
                                   nil, 0, UInt16(bytes.count), bytes.baseAddress,
                                   { _, _, _, _, _, _, _ in }, nil)
            }
            if iconStatus == noError, let deviceInfo = deviceInfo {
                iconStatus = DNSServiceSetDispatchQueue(deviceInfo, .main)
            }
            if iconStatus != noError {
                logger.debug("Mac File Sharing: no model for \(instance) (DNS-SD error \(iconStatus))")
            }
        }
        if status != noError {
            logger.error("Mac File Sharing: cannot publish \(instance) (DNS-SD error \(status))")
            unregister()
        } else {
            logger.info("Mac File Sharing: guest SMB listed as \(instance) on local port \(port)")
        }
    }

    /// Uses the guest's computer name once its agent answers (checked every 10 s for 10 minutes).
    func adoptGuestName(from vm: UTMQemuVirtualMachine) {
        nameTask?.cancel()
        nameTask = Task { [weak self, weak vm] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let vm = vm, let agent = await vm.guestAgent else {
                    continue
                }
                guard let name = await Self.guestOutput(agent, "/usr/sbin/scutil", ["--get", "ComputerName"]) else {
                    continue
                }
                let model = await Self.guestOutput(agent, "/usr/sbin/sysctl", ["-n", "hw.model"])
                guard let self = self, !Task.isCancelled else {
                    return
                }
                self.instance = name
                self.model = model
                self.start()
                return
            }
        }
    }

    private static func guestOutput(_ agent: QEMUGuestAgent, _ path: String, _ arguments: [String]) async -> String? {
        do {
            let pid = try await agent.guestExec(path, argv: arguments, envp: nil, input: nil, captureOutput: true)
            for _ in 0..<40 {
                let status = try await agent.guestExecStatus(pid)
                if status.hasExited {
                    guard status.exitCode == 0, let data = status.outData,
                          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else {
                        return nil
                    }
                    // DNS-SD instance names are at most 63 bytes of UTF-8
                    var name = text
                    while name.utf8.count > 63 {
                        name.removeLast()
                    }
                    return name
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch {
            logger.debug("Mac File Sharing: guest \(path): \(error.localizedDescription)")
        }
        return nil
    }

    func stop() {
        nameTask?.cancel()
        nameTask = nil
        unregister()
    }

    private func unregister() {
        if let deviceInfo = deviceInfo {
            DNSServiceRefDeallocate(deviceInfo)
            self.deviceInfo = nil
        }
        if let service = service {
            DNSServiceRefDeallocate(service)
            self.service = nil
        }
        if let connection = addressConnection {
            DNSServiceRefDeallocate(connection)
            addressConnection = nil
        }
    }
}
