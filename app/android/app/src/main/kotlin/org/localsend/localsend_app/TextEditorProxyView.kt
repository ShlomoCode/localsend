package org.localsend.localsend_app

import android.content.Context
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

// TODO: Remove this proxy and its MainActivity setup once the pinned Flutter version
// includes the fix for https://github.com/flutter/flutter/issues/177360 and TV input is verified.
/** A focused Android view that exposes Flutter's editor connection to TV keyboards. */
internal class TextEditorProxyView(
    context: Context,
    private val flutterView: View,
) : View(context) {
    init {
        isFocusable = true
        isFocusableInTouchMode = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    // The view can act as an editor. Flutter returns no InputConnection when
    // there is no active text client, so this does not open an idle keyboard.
    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? = flutterView.onCreateInputConnection(outAttrs)

    override fun checkInputConnectionProxy(view: View): Boolean = view === flutterView
}
