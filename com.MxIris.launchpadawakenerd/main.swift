//
//  main.swift
//  com.MxIris.launchpadawakenerd
//
//  Created by JH on 2025/9/11.
//

import Foundation
import HelperService
import InjectionService
import HelperServer

let server = try await HelperServer(serverType: .machService(name: "com.MxIris.launchpadawakenerd"), services: [InjectionService()])
await server.activate()
try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in }
