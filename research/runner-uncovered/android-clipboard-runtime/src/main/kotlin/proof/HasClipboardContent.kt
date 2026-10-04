package proof
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
class HasClipboardContent(base: Context) : ContextWrapper(base) {
    fun invoke(result: NativeResult) {
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    result.success(clipboard.hasPrimaryClip())
    }
}
