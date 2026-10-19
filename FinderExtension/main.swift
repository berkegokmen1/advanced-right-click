import Foundation
@_silgen_name("NSExtensionMain")
func extensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
_ = extensionMain(CommandLine.argc, CommandLine.unsafeArgv)
