package org.localsend.localsend_app

import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.io.FileNotFoundException

private const val AUTHORITY = "localsend.fixture.documents"
private const val DIR = DocumentsContract.Document.MIME_TYPE_DIR

/** Explicit metadata is required by DocumentsProvider.attachInfo. Robolectric's
 * create(authority) did not inherit all manifest provider flags in batch4.
 */
fun createOpaqueDocumentsProvider(): OpaqueDocumentsProvider {
    org.robolectric.shadows.ShadowLog.stream = System.out
    val application = RuntimeEnvironment.getApplication()
    val info = ProviderInfo().apply {
        authority = AUTHORITY
        name = OpaqueDocumentsProvider::class.java.name
        packageName = application.packageName
        applicationInfo = application.applicationInfo
        exported = true
        grantUriPermissions = true
        readPermission = "android.permission.MANAGE_DOCUMENTS"
        writePermission = "android.permission.MANAGE_DOCUMENTS"
    }
    return Robolectric.buildContentProvider(OpaqueDocumentsProvider::class.java).create(info).get()
}

/** This fixture implements Android's actual DocumentsProvider query routing.
 * IDs deliberately carry no filesystem hierarchy. Only display names do.
 */
class OpaqueDocumentsProvider : DocumentsProvider() {
    data class Entry(val id: String, val name: String, val mime: String, val size: Long, val modified: Long?)
    var rootId = "16621"
    var childQueryEntered: java.util.concurrent.CountDownLatch? = null
    var releaseChildQuery: java.util.concurrent.CountDownLatch? = null
    var childQueryThread: Thread? = null
    val queriedDocuments = mutableListOf<String>()
    val queriedParents = mutableListOf<String>()
    private fun entries() = listOf(
        Entry(rootId, "Download", DIR, 0, null),
        Entry("msf:16640", "Book.azw3", "application/octet-stream", 7, null),
        Entry("folder:opaque/900", "Comics", DIR, 0, null),
        Entry("msf:16641", "vol01.cbz", "application/zip", 11, 1700000000000L),
    ).associateBy { it.id }

    override fun onCreate() = true
    override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(
        projection ?: arrayOf(DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_DOCUMENT_ID)
    )
    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        queriedDocuments.add(documentId)
        return cursor(projection, listOfNotNull(entries()[documentId]))
    }
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        queriedParents.add(parentDocumentId)
        if (parentDocumentId == rootId) {
            childQueryThread = Thread.currentThread()
            childQueryEntered?.countDown()
            releaseChildQuery?.await(5, java.util.concurrent.TimeUnit.SECONDS)
        }
        val ids = when (parentDocumentId) {
            rootId -> listOf("msf:16640", "folder:opaque/900")
            "folder:opaque/900" -> listOf("msf:16641")
            else -> emptyList()
        }
        return cursor(projection, ids.mapNotNull { entries()[it] })
    }
    override fun isChildDocument(parentDocumentId: String, documentId: String) = entries().containsKey(documentId)
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        throw FileNotFoundException("Content bytes aren't needed for metadata enumeration")
    }
    private fun cursor(projection: Array<out String>?, entries: List<Entry>): Cursor {
        val columns = projection ?: arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        return MatrixCursor(columns).apply {
            for (entry in entries) addRow(columns.map { column -> when (column) {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID -> entry.id
                DocumentsContract.Document.COLUMN_DISPLAY_NAME -> entry.name
                DocumentsContract.Document.COLUMN_MIME_TYPE -> entry.mime
                DocumentsContract.Document.COLUMN_SIZE -> entry.size
                DocumentsContract.Document.COLUMN_LAST_MODIFIED -> entry.modified
                else -> null
            } }.toTypedArray())
        }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [ModernQueryResolverShadow::class])
class OpaqueFolderTest {
    @Test fun actualNativeEnumerationPreservesRootAndNestedDisplayNamesForOpaqueIds() {
        val context = RuntimeEnvironment.getApplication()
        val provider = createOpaqueDocumentsProvider()
        val evidence = JSONArray()
        // Numeric, no-colon, colon, and encoded slash/colon provider IDs must all behave identically.
        for (rootId in listOf("16621", "opaqueRoot", "msf:16621", "opaque/root:16621")) {
            provider.rootId = rootId
            val tree = DocumentsContract.buildTreeDocumentUri(AUTHORITY, rootId)
            assertEquals(rootId, DocumentsContract.getTreeDocumentId(tree))
            val before = BeforeEnumerator(context).enumerate(tree)
            assertEquals(listOf("Book.azw3", "vol01.cbz"), before.map { it.name })
            val after = AfterEnumerator(context).enumerate(tree)
            assertEquals(listOf("Download/Book.azw3", "Download/Comics/vol01.cbz"), after.map { it.name })
            assertEquals(listOf(7L, 11L), after.map { it.size })
            assertEquals(listOf(null, "2023-11-14T22:13:20.000Z"), after.map { it.lastModified })
            assertEquals(before.map { it.uri }, after.map { it.uri })
            assertEquals(listOf("msf:16640", "msf:16641"), after.map { DocumentsContract.getDocumentId(Uri.parse(it.uri)) })
            assertTrue(provider.queriedDocuments.contains(rootId))
            assertTrue(provider.queriedParents.contains("folder:opaque/900"))
            // Also exercise a tree/document URI, the recursive fromTreeUri branch.
            val rootDocument = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
            assertEquals(after, AfterEnumerator(context).enumerate(rootDocument))
            val row = JSONObject().put("rootId", rootId).put("treeUri", tree.toString())
                .put("before", JSONArray(before.map { JSONObject(it.toMap()) }))
                .put("after", JSONArray(after.map { JSONObject(it.toMap()) }))
            evidence.put(row)
        }
        val outputDir = File(System.getProperty("fixture.output", "build/fixture-evidence"))
        outputDir.mkdirs()
        File(outputDir, "native-folder-metadata.json").writeText(evidence.toString(2))
        println("NATIVE_FOLDER_EVIDENCE=" + evidence.toString())
    }
}
