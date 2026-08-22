package com.ecycloud.client

import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File

// 应用私有目录只能由自家 DocumentsProvider 对外暴露：FileProvider 的契约里只有单个
// 文件的读写，没有列目录，系统「文件」应用无从进入 filesDir
class LogDocumentsProvider : DocumentsProvider() {

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(projection ?: ROOT_PROJECTION)
        val resources = requireNotNull(context).resources
        cursor.newRow()
            .add(Root.COLUMN_ROOT_ID, ROOT_ID)
            .add(Root.COLUMN_DOCUMENT_ID, ROOT_ID)
            .add(Root.COLUMN_TITLE, resources.getString(R.string.app_name))
            .add(Root.COLUMN_SUMMARY, resources.getString(R.string.documents_root_logs))
            .add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY)
            .add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
            .add(Root.COLUMN_MIME_TYPES, MIME_LOG)
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_PROJECTION)
        cursor.addDocument(documentId, fileFor(documentId))
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_PROJECTION)
        fileFor(parentDocumentId).listFiles()?.sortedBy { it.name }?.forEach {
            cursor.addDocument("$parentDocumentId/${it.name}", it)
        }
        return cursor
    }

    // COLUMN_FLAGS 里没有写入位，据此只开只读句柄
    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor = ParcelFileDescriptor.open(
        fileFor(documentId),
        ParcelFileDescriptor.MODE_READ_ONLY,
    )

    private fun fileFor(documentId: String): File {
        val root = logsDir(requireNotNull(context))
        if (documentId == ROOT_ID) {
            return root
        }
        return BoxState.resolveWithin(root, documentId.removePrefix("$ROOT_ID/"))
    }

    private fun MatrixCursor.addDocument(documentId: String, file: File) {
        newRow()
            .add(Document.COLUMN_DOCUMENT_ID, documentId)
            .add(Document.COLUMN_DISPLAY_NAME, file.name)
            .add(
                Document.COLUMN_MIME_TYPE,
                if (file.isDirectory) Document.MIME_TYPE_DIR else MIME_LOG,
            )
            .add(Document.COLUMN_SIZE, file.length())
            .add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
            .add(Document.COLUMN_FLAGS, 0)
    }

    companion object {
        private const val ROOT_ID = "logs"
        private const val MIME_LOG = "text/plain"

        private val ROOT_PROJECTION = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_FLAGS,
            Root.COLUMN_ICON,
            Root.COLUMN_MIME_TYPES,
        )

        private val DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )

        // Dart 侧 AppPaths.logs 按 paths.data 拼出 <filesDir>/logs，两处必须同一个目录
        private fun logsDir(context: Context): File = File(context.filesDir, "logs")

        fun rootUri(context: Context, path: String): Uri? {
            val wanted = runCatching { File(path).canonicalFile }.getOrNull()
            val logs = runCatching { logsDir(context).canonicalFile }.getOrNull()
            if (wanted == null || wanted != logs) {
                return null
            }
            return DocumentsContract.buildRootUri(
                "${context.packageName}.documents",
                ROOT_ID,
            )
        }
    }
}
