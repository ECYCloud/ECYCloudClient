package com.ecycloud.client;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import com.ecycloud.client.IUiCallback;

interface IKernelService {
    Bundle ping();

    Bundle status(int logCursor);

    Bundle check(in ParcelFileDescriptor config);

    void reload(in ParcelFileDescriptor config);

    void start(in ParcelFileDescriptor config);

    void stop();

    int clearSession();

    // oneway：不该让界面主线程等 Binder 往返
    oneway void registerUi(IUiCallback callback);
}
