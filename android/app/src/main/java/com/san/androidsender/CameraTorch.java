package com.san.androidsender;

import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.os.Handler;
import android.util.Range;
import android.view.Surface;
import java.lang.reflect.Field;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import org.webrtc.CameraEnumerationAndroid;
import org.webrtc.CameraVideoCapturer;

/**
 * Turns the rear camera's light on or off inside WebRTC's running Camera2 session.
 *
 * WebRTC's capturer has no torch control, and Android refuses CameraManager.setTorchMode while the camera is open,
 * so the session's repeating request is rebuilt with the same settings WebRTC uses plus FLASH_MODE_TORCH.
 * The private fields named here belong to webrtc-sdk 150.7871.01; CameraTorchTest fails if an update renames them.
 */
final class CameraTorch {
    static final String[] SESSION_FIELDS = {"cameraThreadHandler", "cameraDevice", "captureSession", "surface",
            "captureFormat", "fpsUnitFactor", "cameraCharacteristics", "state"};

    private CameraTorch() { }

    /** Whether the first back-facing camera has a flash unit. */
    static boolean rearHasFlash(CameraManager manager) {
        try {
            for (String id : manager.getCameraIdList()) {
                CameraCharacteristics info = manager.getCameraCharacteristics(id);
                Integer facing = info.get(CameraCharacteristics.LENS_FACING);
                if (facing == null || facing != CameraCharacteristics.LENS_FACING_BACK) continue;
                return Boolean.TRUE.equals(info.get(CameraCharacteristics.FLASH_INFO_AVAILABLE));
            }
        } catch (Exception unavailable) { }
        return false;
    }

    /** Returns true when the request was applied; false while the session is still opening or on any failure. */
    static boolean set(CameraVideoCapturer capturer, boolean on) {
        try {
            Object session = field(Class.forName("org.webrtc.CameraCapturer"), "currentSession").get(capturer);
            if (session == null || !session.getClass().getName().equals("org.webrtc.Camera2Session")) return false;
            Class<?> type = session.getClass();
            if (!String.valueOf(field(type, "state").get(session)).equals("RUNNING")) return false;
            Handler thread = (Handler) field(type, "cameraThreadHandler").get(session);
            CompletableFuture<Boolean> applied = new CompletableFuture<>();
            thread.post(() -> {
                try { applied.complete(apply(type, session, thread, on)); }
                catch (Exception failed) { applied.complete(false); }
            });
            return applied.get(2, TimeUnit.SECONDS);
        } catch (Exception failed) {
            return false;
        }
    }

    /** Runs on WebRTC's camera thread, mirroring Camera2Session's own request with the flash mode added. */
    private static boolean apply(Class<?> type, Object session, Handler thread, boolean on) throws Exception {
        if (!String.valueOf(field(type, "state").get(session)).equals("RUNNING")) return false;
        CameraDevice device = (CameraDevice) field(type, "cameraDevice").get(session);
        CameraCaptureSession capture = (CameraCaptureSession) field(type, "captureSession").get(session);
        Surface surface = (Surface) field(type, "surface").get(session);
        CameraEnumerationAndroid.CaptureFormat format = (CameraEnumerationAndroid.CaptureFormat) field(type, "captureFormat").get(session);
        int unit = field(type, "fpsUnitFactor").getInt(session);
        CameraCharacteristics info = (CameraCharacteristics) field(type, "cameraCharacteristics").get(session);
        if (device == null || capture == null || surface == null || format == null || info == null || unit == 0) return false;

        CaptureRequest.Builder request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
        request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, new Range<>(format.framerate.min / unit, format.framerate.max / unit));
        request.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
        request.set(CaptureRequest.CONTROL_AE_LOCK, false);
        int[] stabilization = info.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION);
        int[] videoStabilization = info.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES);
        if (contains(stabilization, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)) {
            request.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON);
            request.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF);
        } else if (contains(videoStabilization, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)) {
            request.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON);
            request.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF);
        }
        if (contains(info.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES), CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO))
            request.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
        request.set(CaptureRequest.FLASH_MODE, on ? CaptureRequest.FLASH_MODE_TORCH : CaptureRequest.FLASH_MODE_OFF);
        request.addTarget(surface);
        capture.setRepeatingRequest(request.build(), null, thread);
        return true;
    }

    private static boolean contains(int[] values, int wanted) {
        if (values == null) return false;
        for (int value : values) if (value == wanted) return true;
        return false;
    }

    static Field field(Class<?> type, String name) throws NoSuchFieldException {
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        return field;
    }
}
