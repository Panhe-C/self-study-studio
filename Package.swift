// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PersonalLearningJournal",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PersonalLearningJournal",
            targets: ["PersonalLearningJournal"]
        )
    ],
    targets: [
        .target(
            name: "PersonalLearningJournal",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PersonalLearningJournalTests",
            dependencies: ["PersonalLearningJournal"]
        )
    ]
)
