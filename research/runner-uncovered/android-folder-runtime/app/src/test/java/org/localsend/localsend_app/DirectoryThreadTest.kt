package org.localsend.localsend_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DirectoryThreadTest {
    private fun provider(): OpaqueDocumentsProvider =
        createOpaqueDocumentsProvider()
    private fun pickedIntent(): Intent = Intent().setData(
        DocumentsContract.buildTreeDocumentUri("localsend.fixture.documents", "16621")
    ).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    private class Probe : MethodChannel.Result {
        val successes = mutableListOf<Any?>()
        val errors = mutableListOf<String>()
        val callbackThreads = mutableListOf<Thread>()
        override fun success(result: Any?) { successes.add(result); callbackThreads.add(Thread.currentThread()) }
        override fun error(code: String, message: String?, details: Any?) { errors.add(code); callbackThreads.add(Thread.currentThread()) }
        val calls: Int get() = successes.size + errors.size
    }
    private fun awaitReply(probe: Probe) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (probe.calls == 0 && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        assertEquals("Exactly one result must be delivered", 1, probe.calls)
    }

    @Test fun actualBeforeDirectoryCallbackBlocksUiForProviderIo() {
        val provider = provider()
        provider.childQueryEntered = CountDownLatch(1)
        provider.releaseChildQuery = CountDownLatch(1)
        val controller = Robolectric.buildActivity(BeforeDirectoryActivity::class.java).setup()
        val probe = Probe()
        val uiThread = Thread.currentThread()
        controller.get().begin(probe)
        val releaser = Thread {
            assertTrue(provider.childQueryEntered!!.await(5, TimeUnit.SECONDS))
            Thread.sleep(200)
            provider.releaseChildQuery!!.countDown()
        }.apply { start() }
        val began = System.nanoTime()
        controller.get().deliver(1, Activity.RESULT_OK, pickedIntent())
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - began)
        releaser.join(5000)
        assertTrue("The UI callback remained blocked for the real provider query: $elapsedMs ms", elapsedMs >= 180)
        assertSame(uiThread, provider.childQueryThread)
        assertEquals(1, probe.successes.size)
        println("DIRECTORY_BEFORE_UI_BLOCK_MS=$elapsedMs")
        controller.pause().stop().destroy()
    }

    @Test fun actualAfterReturnsWhileQueryBlockedAndRepliesOnUi() {
        val provider = provider()
        provider.childQueryEntered = CountDownLatch(1)
        provider.releaseChildQuery = CountDownLatch(1)
        val controller = Robolectric.buildActivity(AfterDirectoryActivity::class.java).setup()
        val probe = Probe()
        val uiThread = Thread.currentThread()
        controller.get().begin(probe)
        controller.get().deliver(1, Activity.RESULT_OK, pickedIntent())
        assertTrue(provider.childQueryEntered!!.await(5, TimeUnit.SECONDS))
        assertEquals(0, probe.calls)
        assertNotSame(uiThread, provider.childQueryThread)
        var uiProgressed = false
        android.os.Handler(Looper.getMainLooper()).post { uiProgressed = true }
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue("UI work runs while provider query remains blocked", uiProgressed)
        assertEquals(1L, provider.releaseChildQuery!!.count)
        provider.releaseChildQuery!!.countDown()
        awaitReply(probe)
        assertEquals(1, probe.successes.size)
        assertSame(uiThread, probe.callbackThreads.single())
        controller.pause().stop().destroy()
    }

    @Test fun capturedReplySurvivesSecondPickCancellationWithoutDoubleReply() {
        val provider = provider()
        provider.childQueryEntered = CountDownLatch(1)
        provider.releaseChildQuery = CountDownLatch(1)
        val controller = Robolectric.buildActivity(AfterDirectoryActivity::class.java).setup()
        val first = Probe()
        val second = Probe()
        controller.get().begin(first)
        controller.get().deliver(1, Activity.RESULT_OK, pickedIntent())
        assertTrue(provider.childQueryEntered!!.await(5, TimeUnit.SECONDS))
        controller.get().begin(second)
        controller.get().deliver(1, Activity.RESULT_CANCELED, null)
        assertEquals(listOf("CANCELED"), second.errors)
        provider.releaseChildQuery!!.countDown()
        awaitReply(first)
        assertEquals(1, first.successes.size)
        assertEquals(1, second.calls)
        controller.pause().stop().destroy()
    }

    @Test fun malformedTreeExceptionCompletesCapturedReplyOnUi() {
        provider()
        val controller = Robolectric.buildActivity(AfterDirectoryActivity::class.java).setup()
        val probe = Probe()
        controller.get().begin(probe)
        val malformed = Intent().setData(Uri.parse("content://localsend.fixture.documents/not-a-tree"))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        controller.get().deliver(1, Activity.RESULT_OK, malformed)
        awaitReply(probe)
        assertEquals(listOf("Error"), probe.errors)
        assertSame(Thread.currentThread(), probe.callbackThreads.single())
        controller.pause().stop().destroy()
    }

    @Test fun activityDestructionDoesNotReplyIntoDisposedCaller() {
        val provider = provider()
        provider.childQueryEntered = CountDownLatch(1)
        provider.releaseChildQuery = CountDownLatch(1)
        val controller = Robolectric.buildActivity(AfterDirectoryActivity::class.java).setup()
        val probe = Probe()
        controller.get().begin(probe)
        controller.get().deliver(1, Activity.RESULT_OK, pickedIntent())
        assertTrue(provider.childQueryEntered!!.await(5, TimeUnit.SECONDS))
        controller.pause().stop().destroy()
        provider.releaseChildQuery!!.countDown()
        provider.childQueryThread!!.join(5000)
        assertFalse("Worker finishes its finite traversal", provider.childQueryThread!!.isAlive)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, probe.calls)
    }
}
