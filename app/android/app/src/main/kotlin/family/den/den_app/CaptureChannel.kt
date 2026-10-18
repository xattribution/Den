package family.den.den_app

import android.content.ContentResolver
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Den's capture channel on Android: Gemini Nano through ML Kit's Prompt API, text recognition
 * with ML Kit, PDF pages rendered and read on the device, photos made into JPEGs, and things
 * shared to Den from other apps. Nothing here sends anything off the phone.
 */
class CaptureChannel(private val activity: MainActivity, engine: FlutterEngine) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val shares = mutableListOf<Map<String, Any?>>()
    private var sink: EventChannel.EventSink? = null
    private var model: GenerativeModel? = null

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "family.den/capture").setMethodCallHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, "family.den/capture/shares").setStreamHandler(this)
    }

    private fun gemini(): GenerativeModel = model ?: Generation.getClient().also { model = it }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "abilities" -> scope.launch { result.success(abilities()) }
            "prepareModel" -> {
                scope.launch {
                    try {
                        gemini().download().collect { }
                    } catch (_: Exception) {
                        // Abilities report what came of it.
                    }
                }
                result.success(null)
            }
            "generate" -> scope.launch {
                try {
                    result.success(generate(call.argument("instructions")!!, call.argument("prompt")!!, call.argument("schema")!!))
                } catch (e: Exception) {
                    result.error("generate", "Gemini Nano couldn't read that.", e.message)
                }
            }
            "findText" -> scope.launch {
                try {
                    val bytes = call.argument<ByteArray>("bytes")!!
                    val type = call.argument<String>("mimeType") ?: ""
                    result.success(withContext(Dispatchers.Default) { if (type == "application/pdf") pdfText(bytes) else imageText(bytes) })
                } catch (e: Exception) {
                    result.error("findText", "This phone couldn't find the text in that.", e.message)
                }
            }
            "toJpeg" -> scope.launch {
                val bytes = call.argument<ByteArray>("bytes")!!
                val side = call.argument<Int>("maxSide") ?: 2000
                result.success(withContext(Dispatchers.Default) { jpeg(bytes, side) })
            }
            "takeShares" -> {
                val out = shares.toList()
                shares.clear()
                result.success(out)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Keeps what [intent] shares, when it shares something, and tells Den. */
    fun receive(intent: Intent?) {
        if (intent == null || (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE)) return
        val resolver = activity.contentResolver
        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND) {
            streamOf(intent)?.let(uris::add)
        } else {
            uris.addAll(streamsOf(intent))
        }
        val files = uris.take(10).mapNotNull { uri -> fileOf(resolver, uri) }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        if (text.isNullOrBlank() && files.isEmpty()) return
        shares.add(mapOf("text" to text, "subject" to subject, "files" to files))
        // Handled once: a configuration change mustn't share it again.
        intent.action = Intent.ACTION_MAIN
        sink?.success(null)
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()

    private fun fileOf(resolver: ContentResolver, uri: Uri): Map<String, Any?>? = try {
        var name: String? = null
        var size = 0L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0)
                size = c.getLong(1)
            }
        }
        if (size > 25L * 1024 * 1024) {
            null
        } else {
            val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null) null else mapOf("bytes" to bytes, "mimeType" to resolver.getType(uri), "name" to name)
        }
    } catch (_: Exception) {
        null
    }

    private suspend fun abilities(): Map<String, Any?> {
        val state = try {
            when (gemini().checkStatus()) {
                FeatureStatus.AVAILABLE -> "available"
                FeatureStatus.DOWNLOADABLE -> "downloadable"
                FeatureStatus.DOWNLOADING -> "downloading"
                else -> "unavailable"
            }
        } catch (_: Exception) {
            "unavailable"
        }
        return mapOf(
            "model" to if (state == "unavailable") null else "gemini-nano",
            "modelName" to "Gemini Nano",
            "modelState" to state,
            "text" to true,
            "pdf" to true,
        )
    }

    /** Gemini Nano's answer, asked for JSON in the schema's shape (its input stays under 4,000 tokens). */
    private suspend fun generate(instructions: String, prompt: String, schema: String): String? {
        val ask = "$prompt\n\nAnswer with one JSON object, and nothing else, in this JSON Schema:\n$schema"
        val request = generateContentRequest(SystemInstruction(instructions), TextPart(ask.take(9000))) {
            temperature = 0.1f
            maxOutputTokens = 2048
        }
        return gemini().generateContent(request).candidates.firstOrNull()?.text
    }

    private suspend fun imageText(bytes: ByteArray): String? {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        return recognize(bitmap)
    }

    private suspend fun recognize(bitmap: Bitmap): String = suspendCancellableCoroutine { done ->
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            .process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { text ->
                // Blocks become paragraphs, so a flyer's sections stay apart.
                done.resume(text.textBlocks.joinToString("\n\n") { it.text })
            }
            .addOnFailureListener { done.resumeWithException(it) }
    }

    /** The text of a PDF's first pages, rendered and recognized on the phone. */
    private suspend fun pdfText(bytes: ByteArray): String? {
        val file = File.createTempFile("den-share", ".pdf", activity.cacheDir)
        try {
            file.writeBytes(bytes)
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                PdfRenderer(fd).use { pdf ->
                    val pages = mutableListOf<String>()
                    for (i in 0 until minOf(pdf.pageCount, 5)) {
                        pdf.openPage(i).use { page ->
                            val scale = 2
                            val bitmap = Bitmap.createBitmap(page.width * scale, page.height * scale, Bitmap.Config.ARGB_8888)
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            pages.add(recognize(bitmap))
                            bitmap.recycle()
                        }
                    }
                    return pages.joinToString("\n\n").ifBlank { null }
                }
            }
        } finally {
            file.delete()
        }
    }

    private fun jpeg(bytes: ByteArray, maxSide: Int): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        val longest = maxOf(decoded.width, decoded.height)
        val scaled = if (longest > maxSide) {
            val f = maxSide.toFloat() / longest
            Bitmap.createScaledBitmap(decoded, (decoded.width * f).toInt(), (decoded.height * f).toInt(), true)
        } else {
            decoded
        }
        return ByteArrayOutputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
            out.toByteArray()
        }
    }
}
