package com.google.android.apps.aicore.service.multiuser;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

/** The component clients bind first. The class name is fixed by the clients; the work is in gbos.localai. */
public class AiCoreMultiUserService extends Service {
    @Override
    public void onCreate() {
        super.onCreate();
        gbos.localai.Entry.attach(this);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return gbos.localai.Entry.provider();
    }
}
