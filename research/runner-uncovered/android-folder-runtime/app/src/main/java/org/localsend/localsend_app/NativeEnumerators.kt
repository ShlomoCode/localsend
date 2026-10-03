package org.localsend.localsend_app

import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class BeforeEnumerator(context: Context) : ContextWrapper(context) {
    fun enumerate(uri: Uri): List<FileInfo> {
        val files = mutableListOf<FileInfo>()
        listFiles(uri, files)
        return files
    }

    private fun listFiles(uri: Uri, files: MutableList<FileInfo>) {
        val pickedDir: FastDocumentFile = FastDocumentFile.fromTreeUri(this, uri)

        for (file in pickedDir.listFiles()) {
            if (file.isDirectory) {
                // Recursive call
                listFiles(file.uri, files)
            } else if (file.isFile) {
                files.add(
                    FileInfo(
                        name = file.name,
                        size = file.size,
                        uri = file.uri.toString(),
                        lastModified = file.lastModified?.toRfc3339(),
                    ),
                )
            }
        }
    }

}

class AfterEnumerator(context: Context) : ContextWrapper(context) {
    fun enumerate(uri: Uri): List<FileInfo> {
        val files = mutableListOf<FileInfo>()
        listFiles(uri, files)
        return files
    }

    private fun listFiles(uri: Uri, files: MutableList<FileInfo>, parentPath: String? = null) {
        val pickedDir: FastDocumentFile = FastDocumentFile.fromTreeUri(this, uri)
        val relative = parentPath ?: FastDocumentFile.fromDocumentUri(this, pickedDir.uri)?.name ?: error("Missing directory name")

        for (file in pickedDir.listFiles()) {
            if (file.isDirectory) {
                // Recursive call
                listFiles(file.uri, files, "$relative/${file.name}")
            } else if (file.isFile) {
                files.add(
                    FileInfo(
                        name = "$relative/${file.name}",
                        size = file.size,
                        uri = file.uri.toString(),
                        lastModified = file.lastModified?.toRfc3339(),
                    ),
                )
            }
        }
    }

}

data class FileInfo(
    val name: String,
    val size: Long,
    val uri: String,
    val lastModified: String?
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "name" to name,
            "size" to size,
            "uri" to uri,
            "lastModified" to lastModified
        )
    }
}

/// Formats milliseconds since epoch as an RFC 3339 string in UTC.
fun Long.toRfc3339(): String {
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    format.timeZone = TimeZone.getTimeZone("UTC")
    return format.format(Date(this))
}
