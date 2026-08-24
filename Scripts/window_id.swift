#!/usr/bin/env swift
// window_id.swift — print the CoreGraphics window id of an app's Nth on-screen
// window, front-most first. Used by make_screenshots.sh to drive
// `screencapture -l` without guessing coordinates.
//
//   ./Scripts/window_id.swift ClipVault 0

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: window_id.swift <app name> [index]\n".utf8))
    exit(2)
}
let owner = arguments[1]
let index = arguments.count > 2 ? Int(arguments[2]) ?? 0 : 0

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]] ?? []
let matches = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }

guard index < matches.count, let number = matches[index][kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write(Data("no window \(index) for \(owner)\n".utf8))
    exit(1)
}
print(number)
