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

/// Lists a Mac OS X guest's SMB File Sharing in Finder (Network) as "<VM name>-VM".
///
/// Port of VirtualIntelMac 2.2's VIMSMBService (MIT): QEMU forwards the guest's port 445 to a
/// local-only host port; this publishes a local-only DNS-SD `_smb._tcp` service with that port,
/// on a host name that resolves to 127.0.0.1. Nothing is advertised on the network.
@MainActor
final class UTMMacFileSharingService {
    private let instance: String
    private let hostname: String
    private let port: UInt16
    private var addressConnection: DNSServiceRef?
    private var service: DNSServiceRef?

    /// smb:// address Finder can also open directly.
    var url: URL? {
        URL(string: "smb://\(instance)._smb._tcp.local")
    }

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
        stop()
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
        if status != noError {
            logger.error("Mac File Sharing: cannot publish \(instance) (DNS-SD error \(status))")
            stop()
        } else {
            logger.info("Mac File Sharing: guest SMB listed as \(instance) on local port \(port)")
        }
    }

    func stop() {
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
