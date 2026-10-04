package org.localsend.localsend_app

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowContentResolver

/** Robolectric4.13 query5 directly invokes provider.query5. Android14's
 * DocumentsProvider intentionally rejects query5; real ContentResolver transport
 * converts the legacy SQL arguments to a Bundle before provider.query4.
 * Restore only that transport conversion; all actual provider routing/cursors,
 * and all production enumeration methods remain unchanged.
 */
@Implements(ContentResolver::class)
class ModernQueryResolverShadow : ShadowContentResolver() {
    @Implementation(minSdk = 26)
    override fun query(
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?,
    ): Cursor? {
        val args = Bundle()
        if (selection != null) args.putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
        if (selectionArgs != null) args.putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
        if (sortOrder != null) args.putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sortOrder)
        return super.query(uri, projection, args, null)
    }
}
