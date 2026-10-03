package proof
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
class NullFilesReaders(base: Context) : ContextWrapper(base) {
    fun baseline(result: NativeResult) {
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        manager.primaryClip?.run {
          if (itemCount == 0) result.success(null)
          val files: MutableList<String> = mutableListOf()
          for (i in 0 until itemCount) {
            getItemAt(i).uri?.let {
              files.add(it.toString())
            }
          }
          result.success(files)
        }
    }
    fun patched(result: NativeResult) {
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        manager.primaryClip?.run {
          if (itemCount == 0) result.success(null)
          val files: MutableList<String> = mutableListOf()
          for (i in 0 until itemCount) {
            getItemAt(i).uri?.let {
              files.add(it.toString())
            }
          }
          result.success(files)
        } ?: result.success(emptyList<String>())
    }
}
