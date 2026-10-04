package org.localsend.localsend_app

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Gives Android TV's IME a real focused EditText instead of Flutter's text input connection. */
class TvTextFieldFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *>
        return TvTextField(context, messenger, viewId, params)
    }
}

private class TvTextField(context: Context, messenger: BinaryMessenger, viewId: Int, params: Map<*, *>?) : PlatformView {
    private val channel = MethodChannel(messenger, "org.localsend.localsend_app/tv_text_field/$viewId")
    private var layoutObserver: ViewTreeObserver? = null
    private val layoutListener = ViewTreeObserver.OnGlobalLayoutListener { checkImeVisibility() }
    private var imeWasVisible = false
    private var dismissHandled = false
    private var submitted = false
    private var finishing = false
    private var disposed = false
    private val editText = object : EditText(context) {
        override fun onKeyPreIme(keyCode: Int, event: KeyEvent): Boolean {
            if (keyCode == KeyEvent.KEYCODE_BACK) {
                if (event.action == KeyEvent.ACTION_UP) {
                    finishEditingByBack()
                }
                return true
            }
            return super.onKeyPreIme(keyCode, event)
        }

        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            observeImeVisibility()
        }

        override fun onDetachedFromWindow() {
            stopObservingImeVisibility()
            super.onDetachedFromWindow()
        }
    }
    private var updatingFromFlutter = false

    init {
        editText.apply {
            setSingleLine(true)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_DONE
            gravity = Gravity.CENTER
            setTextColor((params?.get("textColor") as? Number)?.toInt() ?: Color.WHITE)
            setHintTextColor((params?.get("hintColor") as? Number)?.toInt() ?: Color.GRAY)
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, (params?.get("textSize") as? Number)?.toFloat() ?: 16f)
            typeface = Typeface.DEFAULT
            setBackgroundColor(Color.TRANSPARENT)
            setPadding(0, 0, 0, 0)
            setText(params?.get("text") as? String ?: "")
            setSelection(text.length)
            setOnEditorActionListener { _, actionId, event ->
                val isEnter = event?.keyCode == KeyEvent.KEYCODE_ENTER || event?.keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER
                if (actionId == EditorInfo.IME_ACTION_DONE || (actionId == EditorInfo.IME_NULL && isEnter)) {
                    // TextView calls the listener on both key down and key up for hardware Enter.
                    // Android 14 reports IME_ACTION_DONE rather than IME_NULL for a single-line field.
                    if (event == null || event.action == KeyEvent.ACTION_UP) submitOnce()
                    true
                } else {
                    false
                }
            }
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                    if (!updatingFromFlutter) channel.invokeMethod("changed", s.toString())
                }
                override fun afterTextChanged(s: Editable?) = Unit
            })
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setText" -> {
                    val value = call.arguments as? String ?: ""
                    if (editText.text.toString() != value) {
                        updatingFromFlutter = true
                        try {
                            editText.setText(value)
                            editText.setSelection(value.length)
                        } finally {
                            updatingFromFlutter = false
                        }
                    }
                    result.success(null)
                }
                "focus" -> {
                    if (!editText.hasFocus()) {
                        dismissHandled = false
                        submitted = false
                        finishing = false
                    }
                    editText.requestFocus()
                    editText.post {
                        if (editText.isAttachedToWindow && editText.hasFocus()) {
                            (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                                .showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
                        }
                    }
                    result.success(null)
                }
                "setStyle" -> {
                    val style = call.arguments as? Map<*, *>
                    (style?.get("textColor") as? Number)?.let { editText.setTextColor(it.toInt()) }
                    (style?.get("textSize") as? Number)?.let {
                        editText.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, it.toFloat())
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun getView(): View = editText

    private fun submitOnce() {
        if (submitted || disposed) return
        submitted = true
        finishing = true
        hideKeyboard()
        channel.invokeMethod("submitted", null)
    }

    private fun finishEditingByBack() {
        if (dismissHandled || finishing || disposed) return
        dismissHandled = true
        hideKeyboard()
        editText.clearFocus()
        channel.invokeMethod("keyboardDismissed", null)
    }

    private fun observeImeVisibility() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || disposed || layoutObserver != null) return
        val observer = editText.rootView.viewTreeObserver
        layoutObserver = observer
        observer.addOnGlobalLayoutListener(layoutListener)
        checkImeVisibility()
    }

    private fun stopObservingImeVisibility() {
        layoutObserver?.let { if (it.isAlive) it.removeOnGlobalLayoutListener(layoutListener) }
        layoutObserver = null
        imeWasVisible = false
    }

    private fun checkImeVisibility() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || disposed) return
        // Query the root's original insets, even if Flutter consumed the child's dispatch.
        val visible = editText.rootView.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) ?: return
        if (visible) {
            imeWasVisible = true
        } else if (imeWasVisible) {
            imeWasVisible = false
            if (editText.hasFocus()) finishEditingByBack()
        }
    }

    private fun hideKeyboard() {
        val inputMethodManager = editText.context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        if (inputMethodManager.isActive(editText)) {
            inputMethodManager.hideSoftInputFromWindow(editText.windowToken, 0)
        }
    }

    override fun dispose() {
        disposed = true
        stopObservingImeVisibility()
        hideKeyboard()
        channel.setMethodCallHandler(null)
        editText.clearFocus()
    }
}
