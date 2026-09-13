// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tradutor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .executable(name: "tradutor-probe", targets: ["tradutor-probe"]),
        .library(name: "TradutorCore", targets: ["TradutorCore"]),
        .executable(name: "TradutorApp", targets: ["TradutorApp"]),
        .executable(name: "tradutor-verify", targets: ["tradutor-verify"]),
    ],
    dependencies: [
        // Reconhecimento amplo, inclusive CJK. Whisper large-v3-turbo no ANE.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Reconhecimento rapido para os 25 idiomas europeus (Parakeet-TDT v3).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.5.0"),
    ],
    targets: [
        // Fase 1-3: captura, normalizacao e segmentacao.
        // Sem dependencias externas de proposito: essa camada precisa
        // compilar e rodar em segundos para poder ser depurada sozinha.
        .target(
            name: "AudioCapture",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Fases 4 e 5: reconhecimento e traducao. Depende do que e pesado,
        // entao fica separado da camada de captura.
        .target(
            name: "TradutorCore",
            dependencies: [
                "AudioCapture",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Fases 6 e 7: painel flutuante, atalho global e barra de menus.
        .executableTarget(
            name: "TradutorApp",
            dependencies: ["TradutorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Resources/app-Info.plist",
            ])]
        ),
        // Portoes das fases 4 e 5, rodaveis sem captura de audio.
        .executableTarget(
            name: "tradutor-verify",
            dependencies: ["TradutorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "tradutor-probe",
            dependencies: ["AudioCapture"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Um binario de linha de comando sem Info.plist embutido nao
            // consegue pedir permissao de captura de audio: o sistema entrega
            // silencio digital em vez de negar com erro.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Resources/probe-Info.plist",
            ])]
        ),
    ]
)
