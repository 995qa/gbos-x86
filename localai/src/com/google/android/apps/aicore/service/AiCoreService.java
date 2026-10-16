package com.google.android.apps.aicore.service;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

/** The fallback component clients bind when the multi-user one is unavailable: serves the core service directly. */
public class AiCoreService extends Service {
    @Override
    public IBinder onBind(Intent intent) {
        return gbos.localai.Entry.core();
    }
}
