package org.localsend.localsend_app

import android.content.Context
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

/** A focused Android view that exposes Flutter's editor connection to TV keyboards. */
internal class TextEditorProxyView(
    context: Context,
    private val flutterView: View,
    private val isEditorActive: () -> Boolean,
) : View(context) {
    init {
        isFocusable = true
        isFocusableInTouchMode = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onCheckIsTextEditor(): Boolean = isEditorActive()

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? = flutterView.onCreateInputConnection(outAttrs)

    override fun checkInputConnectionProxy(view: View): Boolean = view === flutterView
}
