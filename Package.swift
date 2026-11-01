// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "XMPViewCore", targets: ["XMPViewCore"])]
var targets: [Target] = [
    .target(name: "XMPViewCore"),
    .testTarget(name: "XMPViewCoreTests", dependencies: ["XMPViewCore"], resources: [.copy("Fixtures")])
]

#if os(macOS)
products += [.executable(name: "XMPView", targets: ["XMPViewApp"])]
targets += [
    .target(name: "XMPViewImageIO", dependencies: ["XMPViewCore"]),
    .executableTarget(name: "XMPViewApp", dependencies: ["XMPViewCore", "XMPViewImageIO"]),
    .testTarget(name: "XMPViewImageIOTests", dependencies: ["XMPViewCore", "XMPViewImageIO"])
]
#endif

let package = Package(
    name: "XMPView",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
