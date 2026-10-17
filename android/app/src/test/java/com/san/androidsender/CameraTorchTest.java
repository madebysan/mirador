package com.san.androidsender;

import org.junit.Test;
import static org.junit.Assert.*;

public class CameraTorchTest {
    /** The torch reaches into WebRTC's private Camera2 session; a library update that renames these fields must fail here. */
    @Test public void webRtcCameraFieldsStillExist() throws Exception {
        ClassLoader loader = getClass().getClassLoader();
        assertNotNull(CameraTorch.field(Class.forName("org.webrtc.CameraCapturer", false, loader), "currentSession"));
        Class<?> session = Class.forName("org.webrtc.Camera2Session", false, loader);
        for (String name : CameraTorch.SESSION_FIELDS) assertNotNull(name, CameraTorch.field(session, name));
        assertNotNull(CameraTorch.field(Class.forName("org.webrtc.CameraEnumerationAndroid$CaptureFormat", false, loader), "framerate"));
    }
}
