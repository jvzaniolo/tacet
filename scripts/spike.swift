// Sends a spike command to a running MenuShelf. Build once:
//   swiftc -o build/spike scripts/spike.swift
// then e.g.: build/spike spacer 600 image | build/spike probe | build/spike watch on
import Foundation

let command = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.menushelf.spike"), object: command, userInfo: nil, deliverImmediately: true)
print("sent: \(command)")
