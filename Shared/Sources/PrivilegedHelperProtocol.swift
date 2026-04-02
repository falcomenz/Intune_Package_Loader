import Foundation

let privilegedHelperLabel = "de.axelspringer.intune.package-loader.mirror-service"
let defaultRootDirectoryPath = "/Library/Application Support/Intune_Package_Loader"

@objc protocol IntunePackageMirrorHelperProtocol {
    func fetchMirrorStatus(_ rootDirectory: String, withReply reply: @escaping (Bool, String?) -> Void)
    func startMirror(_ rootDirectory: String, withReply reply: @escaping (String?) -> Void)
    func stopMirror(withReply reply: @escaping (String?) -> Void)
    func cleanupPackages(_ rootDirectory: String, withReply reply: @escaping (String?) -> Void)
}
