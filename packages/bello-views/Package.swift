// swift-tools-version: 6.0
import PackageDescription

// Views Bello Agent shows beside its chats, kept apart from the app so another
// app can show them too. Each is a product of its own, depending on nothing of
// the apps that host them: they give it their chrome, colours and fonts.
//
// FileView: a file of any size, read away from the main thread (its lines
// found, its encoding known, its text read a screen at a time), drawn,
// selected and read to VoiceOver by an AppKit view.
//
// GitView: a repository's changes, history and diffs, read with git, watched
// for changes, and the diff drawn by an AppKit table.
//
// FileFinder: a project's files listed (as git lists them, or walked as its
// ignore files say) and found by part of their name, away from the main
// thread.
let package = Package(
    name: "BelloViews",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BelloFileView", targets: ["FileView"]),
        .library(name: "BelloGitView", targets: ["GitView"]),
        .library(name: "BelloFileFinder", targets: ["FileFinder"]),
    ],
    targets: [
        .target(name: "FileView"),
        .testTarget(name: "FileViewTests", dependencies: ["FileView"]),
        .target(name: "GitView"),
        .testTarget(name: "GitViewTests", dependencies: ["GitView"]),
        .target(name: "FileFinder"),
        .testTarget(name: "FileFinderTests", dependencies: ["FileFinder"]),
    ]
)
