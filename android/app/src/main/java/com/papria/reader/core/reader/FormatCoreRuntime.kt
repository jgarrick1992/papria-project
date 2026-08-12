package com.papria.reader.core.reader

import com.papria.reader.BuildConfig
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.util.Locale

/**
 * Runtime boundary for the mandatory generated UniFFI binding.
 *
 * Every Android variant builds and packages the generated Kotlin binding and
 * ABI libraries. Reflection keeps this source tied to UniFFI's exact emitted
 * JVM names without introducing a second hand-written contract.
 */
object FormatCoreRuntime {
    // This is the exact JVM class name generated from
    // `papria_format_core.kt`; it is intentionally not normalized or aliased.
    private const val BINDING_CLASS = "uniffi.papria_format_core.Papria_format_coreKt"
    /**
     * UniFFI's generated Android loader uses this exact component name. The
     * native packaging script normalises cargo-ndk's `libpapria_format_core.so`
     * output to this name before Gradle consumes the ABI directories.
     */
    private const val NATIVE_LIBRARY = "uniffi_papria_format_core"

    @Volatile
    private var loaded = false

    val enabled: Boolean
        get() = BuildConfig.NATIVE_FORMAT_CORE

    /**
     * Open the caller-owned file through UniFFI's bounded random-access
     * callback and validate the real ZIP/RAR4/7z container before a platform
     * decoder sees it. This is deliberately not a metadata mirror: especially
     * for solid CB7, Rust validates trusted packed-stream groups that Commons
     * Compress does not expose per member.
     *
     * Unit tests run on the JVM and cannot load an Android ELF library, so
     * they exercise the decoder's equivalent local limits. Every installed
     * Android build must call this path.
     */
    fun inspectComicArchive(file: File, expectedKind: String) {
        if (!enabled || !isAndroidRuntime()) return
        require(file.isFile && file.length() in 1..MAX_ARCHIVE_BYTES) { "invalid comic archive" }
        ensureLoaded()
        val sourceClass = Class.forName("uniffi.papria_format_core.ArchiveByteSource")
        val source = Proxy.newProxyInstance(sourceClass.classLoader, arrayOf(sourceClass)) { proxy, method, arguments ->
            // Kotlin mangles method names containing inline unsigned types.
            // Dispatch on the exact generated JVM ABI instead: ArchiveByteSource
            // exposes only `() -> long` and `(long, int) -> List` here.
            // This avoids accepting alternate source contracts or relying on a
            // compiler-specific mangled suffix.
            when {
                method.declaringClass == Any::class.java && method.name == "equals" ->
                    proxy === arguments?.getOrNull(0)
                method.declaringClass == Any::class.java && method.name == "hashCode" ->
                    System.identityHashCode(proxy)
                method.declaringClass == Any::class.java && method.name == "toString" ->
                    "PapriaArchiveByteSource(${file.name})"
                method.parameterTypes.isEmpty() && method.returnType == java.lang.Long.TYPE -> file.length()
                method.parameterTypes.contentEquals(arrayOf(java.lang.Long.TYPE, java.lang.Integer.TYPE)) &&
                    List::class.java.isAssignableFrom(method.returnType) -> {
                    val offset = arguments?.getOrNull(0) as? Long
                        ?: error("missing archive read offset")
                    val length = arguments.getOrNull(1) as? Int
                        ?: error("missing archive read length")
                    readArchiveSlice(file, offset, length)
                }
                else -> error("unsupported generated ArchiveByteSource ABI")
            }
        }
        val limits = invoke("defaultArchiveLimits")
            ?: error("missing UniFFI defaultArchiveLimits result")
        val inspection = invoke("inspectComicArchive", source, limits)
            ?: error("missing UniFFI comic archive inspection result")
        val kind = inspection.javaClass.methods.firstOrNull {
            it.name == "getKind" && it.parameterTypes.isEmpty()
        }?.invoke(inspection)?.toString() ?: error("invalid UniFFI comic archive inspection result")
        require(kind == expectedKind) { "comic archive signature does not match its file type" }
    }

    fun validateFilename(filename: String) {
        if (!enabled) return
        ensureLoaded()
        invoke("validateFilename", filename)
    }

    /**
     * Run the shared bounded extension/signature check when the native gate is
     * enabled. The enum's generated name is returned verbatim (for example
     * `EPUB`); callers must compare it with their own format value and must not
     * invent alternate wire names.
     */
    fun detectFormat(filename: String, header: ByteArray): String? {
        if (!enabled) return null
        ensureLoaded()
        val bytes = header.map { it.toUByte() }
        return invoke("detectFormat", filename, bytes)?.toString()
    }

    /** Convert through the shared Rust core in every installed app variant. */
    fun convertToInternalEpubFile(source: File, extension: String): File? {
        if (!enabled) return null
        require(source.isFile && source.length() <= MAX_INPUT_BYTES) { "format-core input exceeds safety limit" }
        ensureLoaded()
        val output = File(source.parentFile ?: return null, ".${source.name}.native.papria.epub")
        if (output.isFile && output.length() > 0 && output.lastModified() >= source.lastModified()) return output
        val bytes = source.inputStream().use { it.readBytes() }
        val formatClass = Class.forName("uniffi.papria_format_core.SupportedFormat")
        @Suppress("UNCHECKED_CAST")
        val format = java.lang.Enum.valueOf(
            formatClass as Class<out Enum<*>>,
            extension.trim().uppercase(Locale.US),
        )
        val result = invoke("convertToInternalEpub", format, bytes.map { it.toUByte() })
        val outputBytes = (result as? List<*>)?.map { value ->
            when (value) {
                is UByte -> value.toInt()
                is Number -> value.toInt()
                else -> error("unexpected UniFFI byte type")
            }.and(0xff).toByte()
        }?.toByteArray() ?: return null
        if (outputBytes.isEmpty()) return null
        val temporary = File(output.parentFile, ".${output.name}.part")
        FileOutputStream(temporary).use { it.write(outputBytes) }
        check(temporary.renameTo(output)) { "unable to publish converted EPUB" }
        return output
    }

    @Synchronized
    private fun ensureLoaded() {
        if (loaded) return
        runCatching { System.loadLibrary(NATIVE_LIBRARY) }
            .getOrElse {
                throw IllegalStateException(
                    "Papria native format core is enabled but lib$NATIVE_LIBRARY is unavailable",
                    it,
                )
            }
        runCatching { Class.forName(BINDING_CLASS) }
            .getOrElse { throw IllegalStateException("Papria native format core binding is unavailable", it) }
        loaded = true
    }

    private fun invoke(methodName: String, vararg args: Any?): Any? {
        try {
            val method = Class.forName(BINDING_CLASS).methods.firstOrNull { candidate ->
                candidate.name == methodName && candidate.parameterTypes.size == args.size
            } ?: error("missing UniFFI method $methodName")
            return method.invoke(null, *args)
        } catch (error: InvocationTargetException) {
            throw (error.targetException ?: error)
        } catch (error: ReflectiveOperationException) {
            throw IllegalStateException("unable to invoke UniFFI method $methodName", error)
        }
    }

    private fun isAndroidRuntime(): Boolean = runCatching {
        Class.forName("android.os.Build\$VERSION")
            .getField("SDK_INT")
            .getInt(null) > 0
    }.getOrDefault(false)

    private const val MAX_INPUT_BYTES = 256L * 1024 * 1024
    private const val MAX_ARCHIVE_BYTES = 8L * 1024 * 1024 * 1024
    private const val MAX_ARCHIVE_READ_BYTES = 64 * 1024

    private fun readArchiveSlice(file: File, start: Long, length: Int): List<UByte> {
        require(start >= 0L && length in 0..MAX_ARCHIVE_READ_BYTES) { "invalid archive read request" }
        require(start <= file.length() && length.toLong() <= file.length() - start) { "archive read is outside file bounds" }
        val bytes = ByteArray(length)
        RandomAccessFile(file, "r").use { input ->
            input.seek(start)
            input.readFully(bytes)
        }
        return bytes.map { it.toUByte() }
    }
}
