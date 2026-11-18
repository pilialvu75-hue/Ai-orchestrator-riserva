package dev.aivexus.adskill;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;

/** Non-exported provider, read-only APK; OS grants installer one temporary URI. */
public final class UpdateApkProvider extends ContentProvider {
    static final String AUTHORITY = "dev.aivexus.adskill.updates";
    static final Uri APK_URI = Uri.parse("content://" + AUTHORITY + "/apk");
    static final String MIME = "application/vnd.android.package-archive";

    private File file(Uri uri) throws FileNotFoundException {
        if (!"/apk".equals(uri.getPath()) || getContext() == null)
            throw new FileNotFoundException("Unknown update path");
        File file = new File(getContext().getCacheDir(), "adskill_update.apk");
        if (!file.isFile()) throw new FileNotFoundException("No verified update available");
        return file;
    }

    @Override public boolean onCreate() { return true; }

    @Override public String getType(Uri uri) { return MIME; }

    @Override public Cursor query(Uri uri, String[] projection, String selection,
                                   String[] selectionArgs, String sortOrder) {
        try {
            File f = file(uri);
            String[] cols = projection == null
                ? new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}
                : projection;
            MatrixCursor cursor = new MatrixCursor(cols);
            Object[] row = new Object[cols.length];
            for (int i = 0; i < cols.length; i++) {
                if (OpenableColumns.DISPLAY_NAME.equals(cols[i])) row[i] = "AdsKill-update.apk";
                if (OpenableColumns.SIZE.equals(cols[i])) row[i] = f.length();
            }
            cursor.addRow(row);
            return cursor;
        } catch (FileNotFoundException e) {
            return new MatrixCursor(new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        }
    }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode)
            throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read only");
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException();
    }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }
}
