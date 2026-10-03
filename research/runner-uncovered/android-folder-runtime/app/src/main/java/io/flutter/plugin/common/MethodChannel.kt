package io.flutter.plugin.common
// Fixture scaffold only: the actual callback invokes this Flutter Result contract.
class MethodChannel {
    interface Result {
        fun success(result: Any?)
        fun error(code: String, message: String?, details: Any?)
    }
}
