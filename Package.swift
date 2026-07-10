// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PersonalLearningJournal",
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
            name: "PersonalLearningJournal"
        ),
        .testTarget(
            name: "PersonalLearningJournalTests",
            dependencies: ["PersonalLearningJournal"]
        )
    ]
)
