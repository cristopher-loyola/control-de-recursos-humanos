package com.example.kiosk

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.opencv.android.OpenCVLoader
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import org.opencv.objdetect.FaceDetectorYN
import org.opencv.objdetect.FaceRecognizerSF
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.math.sqrt

/** All inference and encryption run on one background worker, entirely on-device. */
class FaceEngine(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "accesos/face_engine")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: FaceRecognizerSF? = null
    private var detector: FaceDetectorYN? = null
    // Último cuadro analizado: SFace alinea con la misma detección de YuNet, sin convertir puntos.
    private var lastFrame: Mat? = null
    private var lastFaces: Mat? = null

    init {
        channel.setMethodCallHandler { call, result ->
            worker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "initialize" -> { model(); true }
                        "extract" -> extract(call.arguments as Map<*, *>)
                        "detect" -> detect(call.arguments as Map<*, *>)
                        "extractDetected" -> extractDetected((call.arguments as Number).toInt())
                        "seal" -> crypt(call.arguments as Map<*, *>, true)
                        "unseal" -> crypt(call.arguments as Map<*, *>, false)
                        "cameraRotation" -> context.getSharedPreferences("face_camera", Context.MODE_PRIVATE).getBoolean("half_turn", false)
                        "setCameraRotation" -> { context.getSharedPreferences("face_camera", Context.MODE_PRIVATE).edit().putBoolean("half_turn", call.arguments as Boolean).apply(); null }
                        else -> throw IllegalArgumentException("Unsupported operation")
                    }
                    main.post { result.success(value) }
                } catch (error: Exception) {
                    // Never log frames, templates, names or encryption keys.
                    main.post { result.error("FACE_ENGINE", "No se pudo procesar el rostro en esta tablet.", null) }
                }
            }
        }
    }

    /** Copia el modelo empaquetado y comprueba su SHA-256 antes de cargarlo. */
    private fun asset(name: String, cacheName: String, expected: String): File {
        check(OpenCVLoader.initLocal())
        Core.setNumThreads(2)
        val file = File(context.noBackupFilesDir, cacheName)
        fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }
        if (!file.exists() || digest(file.readBytes()) != expected) {
            val bytes = context.assets.open(name).use { it.readBytes() }
            check(digest(bytes) == expected) { "Model integrity failed" }
            file.writeBytes(bytes)
        }
        return file
    }

    private fun model(): FaceRecognizerSF {
        recognizer?.let { return it }
        val file = asset(
            "face/sface.onnx",
            "sface-2021dec.onnx",
            "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
        )
        return FaceRecognizerSF.create(file.absolutePath, "").also { recognizer = it }
    }

    private fun detector(width: Int, height: Int): FaceDetectorYN {
        val size = Size(width.toDouble(), height.toDouble())
        detector?.let { it.inputSize = size; return it }
        val file = asset(
            "face/yunet.onnx",
            "yunet-2023mar.onnx",
            "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
        )
        // Umbral 0.8 y NMS 0.3: valores de la demo de OpenCV Zoo.
        return FaceDetectorYN.create(file.absolutePath, "", size, 0.8f, 0.3f, 5).also { detector = it }
    }

    /** NV21 de la cámara a BGR derecho, según la rotación que calcula Flutter. */
    private fun upright(args: Map<*, *>): Mat {
        val width = (args["width"] as Number).toInt()
        val height = (args["height"] as Number).toInt()
        val rotation = (args["rotation"] as Number).toInt()
        val bytes = args["bytes"] as ByteArray
        require(width in 2..1920 && height in 2..1920 && width % 2 == 0 && height % 2 == 0)
        require(bytes.size == width * height * 3 / 2 && rotation in listOf(0, 90, 180, 270))
        val yuv = Mat(height + height / 2, width, CvType.CV_8UC1)
        val bgr = Mat()
        val result = Mat()
        try {
            yuv.put(0, 0, bytes)
            Imgproc.cvtColor(yuv, bgr, Imgproc.COLOR_YUV2BGR_NV21)
            when (rotation) {
                90 -> Core.rotate(bgr, result, Core.ROTATE_90_CLOCKWISE)
                180 -> Core.rotate(bgr, result, Core.ROTATE_180)
                270 -> Core.rotate(bgr, result, Core.ROTATE_90_COUNTERCLOCKWISE)
                else -> bgr.copyTo(result)
            }
            return result
        } finally {
            yuv.release()
            bgr.release()
        }
    }

    /** Cada rostro: x, y, ancho, alto, 5 puntos (ojo, ojo, nariz, boca, boca) y puntaje. */
    private fun detect(args: Map<*, *>): Map<String, Any> {
        model()
        val frame = upright(args)
        val faces = Mat()
        detector(frame.cols(), frame.rows()).detect(frame, faces)
        lastFrame?.release()
        lastFaces?.release()
        lastFrame = frame
        lastFaces = faces
        val rows = (0 until faces.rows()).map { row ->
            FloatArray(15).also { faces.get(row, 0, it) }.map { it.toDouble() }
        }
        return mapOf("width" to frame.cols(), "height" to frame.rows(), "faces" to rows)
    }

    private fun extractDetected(index: Int): List<Double> {
        val frame = checkNotNull(lastFrame)
        val faces = checkNotNull(lastFaces)
        require(index in 0 until faces.rows())
        val aligned = Mat()
        val feature = Mat()
        val face = faces.row(index)
        try {
            val engine = model()
            engine.alignCrop(frame, face, aligned)
            engine.feature(aligned, feature)
            return normalized(feature)
        } finally {
            listOf(aligned, feature, face).forEach { it.release() }
        }
    }

    private fun normalized(feature: Mat): List<Double> {
        require(feature.total() == 128L)
        val vector = FloatArray(128)
        feature.get(0, 0, vector)
        val norm = sqrt(vector.sumOf { it.toDouble() * it.toDouble() })
        require(norm.isFinite() && norm > 0.000001)
        return vector.map { it.toDouble() / norm }
    }

    private fun extract(args: Map<*, *>): List<Double> {
        val width = (args["width"] as Number).toInt()
        val height = (args["height"] as Number).toInt()
        val rotation = (args["rotation"] as Number).toInt()
        val bytes = args["bytes"] as ByteArray
        val points = (args["landmarks"] as List<*>).map { (it as Number).toFloat() }
        require(width in 2..1920 && height in 2..1920 && width % 2 == 0 && height % 2 == 0)
        require(bytes.size == width * height * 3 / 2 && points.size == 10)
        require(points.all { it.isFinite() } && rotation in listOf(0, 90, 180, 270))
        val engine = model()
        val yuv = Mat(height + height / 2, width, CvType.CV_8UC1)
        val bgr = Mat()
        val upright = Mat()
        val face = Mat(1, 15, CvType.CV_32F)
        val aligned = Mat()
        val feature = Mat()
        try {
            yuv.put(0, 0, bytes)
            Imgproc.cvtColor(yuv, bgr, Imgproc.COLOR_YUV2BGR_NV21)
            when (rotation) {
                90 -> Core.rotate(bgr, upright, Core.ROTATE_90_CLOCKWISE)
                180 -> Core.rotate(bgr, upright, Core.ROTATE_180)
                270 -> Core.rotate(bgr, upright, Core.ROTATE_90_COUNTERCLOCKWISE)
                else -> bgr.copyTo(upright)
            }
            val box = FloatArray(15)
            for (i in points.indices) box[i + 4] = points[i]
            box[14] = 1f
            face.put(0, 0, box)
            engine.alignCrop(upright, face, aligned)
            engine.feature(aligned, feature)
            return normalized(feature)
        } finally {
            listOf(yuv, bgr, upright, face, aligned, feature).forEach { it.release() }
        }
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "accesos.face.templates.v1"
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            generateKey()
        }
    }

    private fun crypt(args: Map<*, *>, encrypt: Boolean): ByteArray {
        val data = args["bytes"] as ByteArray
        val aad = (args["context"] as String).toByteArray(Charsets.UTF_8)
        require(data.size in 1..32768 && aad.size in 1..1024)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (encrypt) {
            cipher.init(Cipher.ENCRYPT_MODE, key())
            cipher.updateAAD(aad)
            return cipher.iv + cipher.doFinal(data)
        }
        require(data.size > 28)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        cipher.updateAAD(aad)
        return cipher.doFinal(data, 12, data.size - 12)
    }

    fun close() {
        channel.setMethodCallHandler(null)
        worker.execute {
            lastFrame?.release()
            lastFaces?.release()
            lastFrame = null
            lastFaces = null
        }
        worker.shutdown()
    }
}
