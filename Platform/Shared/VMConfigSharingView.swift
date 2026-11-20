//
// Copyright © 2020 osy. All rights reserved.
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

import SwiftUI

struct VMConfigSharingView: View {
    @Binding var config: UTMQemuConfigurationSharing
    /// Mac OS X Intel guest (VirtualIntelMac guest kit): offers Mac File Sharing.
    var isIntelMacGuest: Bool = false
    @State private var isImporterPresented: Bool = false
    @EnvironmentObject private var data: UTMData
    
    var body: some View {
        VStack {
            Form {
                DetailedSection("Clipboard Sharing", description: "Requires SPICE guest agent tools to be installed.") {
                    Toggle(isOn: $config.hasClipboardSharing, label: {
                        Text("Enable Clipboard Sharing")
                    })
                }
                
                #if os(macOS)
                if isIntelMacGuest {
                    DetailedSection("Mac File Sharing", description: "Turn on File Sharing (SMB) in the guest's Sharing preferences. With the Emulated network, UTM lists it in Finder under Network as the VM's name followed by -VM; with Shared, Bridged or Host Only networking the guest appears there by its own name. Needs the Intel guest kit.") {
                        Toggle(isOn: $config.hasMacFileSharing, label: {
                            Text("Enable Mac File Sharing")
                        })
                    }
                }
                #endif
                
                DetailedSection("Shared Directory", description: "WebDAV requires installing SPICE daemon. VirtFS requires installing device drivers.") {
                    VMConfigConstantPicker("Directory Share Mode", selection: $config.directoryShareMode)
                    if config.directoryShareMode != .none {
                        FileBrowseField(url: $config.directoryShareUrl, isFileImporterPresented: $isImporterPresented)
                        Toggle(isOn: $config.isDirectoryShareReadOnly, label: {
                            Text("Read Only")
                        })
                    }
                }.globalFileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
                    data.busyWorkAsync {
                        let url = try result.get()
                        await MainActor.run {
                            config.directoryShareUrl = url
                        }
                    }
                }
            }
        }
    }
}

struct VMConfigSharingView_Previews: PreviewProvider {
    @State static private var config = UTMQemuConfigurationSharing()
    
    static var previews: some View {
        VMConfigSharingView(config: $config)
            #if os(macOS)
            .scrollable()
            #endif
    }
}
