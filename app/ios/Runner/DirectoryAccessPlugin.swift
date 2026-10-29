import Flutter
import UIKit

// TODO: Replace this bridge with the released directory lease API from
// https://github.com/ShlomoCode/flutter_file_picker/pull/1 (fixed version unknown).
// Then remove the picker/registry and migrate Dart plus Rust's retain/release ABI.
final class DirectoryAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate,
    UIAdaptivePresentationControllerDelegate {
  private let registrar: FlutterPluginRegistrar
  private var pendingResult: FlutterResult?

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "org.localsend.localsendApp/directory-access",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(DirectoryAccessPlugin(registrar: registrar), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getDirectoryAccess":
      guard pendingResult == nil else {
        result(FlutterError(code: "already_active", message: "A directory picker is already open.", details: nil))
        return
      }
      guard var presenter = registrar.viewController else {
        result(FlutterError(code: "directory_picker_failed", message: "No view controller is available.", details: nil))
        return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      // The document-types initializer preserves iOS 13 support and opens in place.
      let picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
      picker.allowsMultipleSelection = false
      picker.delegate = self
      pendingResult = result
      presenter.present(picker, animated: true)
      picker.presentationController?.delegate = self
    case "releaseDirectoryAccess":
      guard let arguments = call.arguments as? [String: Any], let token = arguments["accessToken"] as? String else {
        result(FlutterError(code: "invalid_argument", message: "A directory access token is required.", details: nil))
        return
      }
      token.withCString { localsend_directory_access_release_v1($0) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard pendingResult != nil else { return }
    guard let url = urls.first, url.isFileURL, !url.path.isEmpty else {
      finish(FlutterError(code: "directory_picker_failed", message: "Could not resolve the selected directory.", details: nil))
      controller.dismiss(animated: true)
      return
    }
    // Only the original picker URL carries the security-scoped permission.
    let token = url.startAccessingSecurityScopedResource() ? LSInsertDirectoryLease(url) : nil
    finish(["path": url.path, "accessToken": token as Any? ?? NSNull()])
    controller.dismiss(animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
    controller.dismiss(animated: true)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(nil)
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }
}
