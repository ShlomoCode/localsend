package proof
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
fun interface NativeResult { fun success(value: Any?) }
class NativeRawClipboard(base: Context) : ContextWrapper(base) {
    fun invoke(result: NativeResult) {
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    try {
                        result.success(clipboard.primaryClip?.getItemAt(0)?.text?.toString())
                    } catch (e: SecurityException) {
                        result.success(null)
                    }
    }
}
