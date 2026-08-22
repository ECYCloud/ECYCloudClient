package com.ecycloud.client;

import android.os.Bundle;
import com.ecycloud.client.IUiCallback;

interface IKernelService {
    Bundle ping();

    Bundle status(int logCursor);

    Bundle check(String config);

    void reload(String config);

    void start(String config);

    void stop();

    // oneway：不该让界面主线程等 Binder 往返
    oneway void registerUi(IUiCallback callback);
}
