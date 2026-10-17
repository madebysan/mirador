package com.san.androidsender;

import android.content.Context;
import android.os.SystemClock;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.TimeoutException;
import org.json.JSONArray;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;
import org.webrtc.*;
import org.webrtc.audio.JavaAudioDeviceModule;
import static com.san.androidsender.PrivateServer.ApiError;

final class StreamEngine implements AutoCloseable {
    private final Context context;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final EglBase egl;
    private final JavaAudioDeviceModule audioDevice;
    private final PeerConnectionFactory factory;
    private PeerConnection peer;
    private CameraVideoCapturer capturer;
    private SurfaceTextureHelper texture;
    private VideoSource videoSource;
    private VideoTrack videoTrack;
    private AudioSource audioSource;
    private AudioTrack audioTrack;
    private RtpSender videoSender;
    private volatile int sendWidth, sendHeight, sendFps, targetKbps;
    private volatile String qualityLimit = "";
    private CompletableFuture<Void> gathered;
    private volatile String session = "", camera = "rear", connection = "idle", error = "";
    private volatile boolean video, microphone, audioInputActive;
    /** Rear-camera light: what the receiver asked for, and whether it is actually on. */
    private volatile boolean torchWanted, torch;
    private Boolean rearFlash;
    private volatile long videoFrames, audioSamples;
    private volatile long generation;
    private long lastPing, disconnectedAt;
    private volatile long sessionStarted;
    private volatile boolean closed;

    StreamEngine(Context context) {
        this.context = context;
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context)
                .setEnableInternalTracer(false).createInitializationOptions());
        Logging.enableLogToDebugOutput(Logging.Severity.LS_ERROR);
        egl = EglBase.create();
        audioDevice = JavaAudioDeviceModule.builder(context)
                .setUseStereoInput(false).setUseStereoOutput(false).setEnableVolumeLogger(false)
                .setAudioRecordStateCallback(new JavaAudioDeviceModule.AudioRecordStateCallback() {
                    public void onWebRtcAudioRecordStart() { audioInputActive = true; }
                    public void onWebRtcAudioRecordStop() { audioInputActive = false; }
                })
                .setSamplesReadyCallback(samples -> audioSamples += samples.getData().length / 2)
                .createAudioDeviceModule();
        PeerConnectionFactory.Options options = new PeerConnectionFactory.Options();
        // Cellular stays available for relayed sessions; private sessions drop non-private candidates from their SDP.
        options.networkIgnoreMask = 0;
        // Android's default-network monitor omits the Tailscale VPN interface.
        // Enumerate bound host interfaces instead; each new viewer gathers fresh candidates.
        options.disableNetworkMonitor = true;
        factory = PeerConnectionFactory.builder().setOptions(options).setAudioDeviceModule(audioDevice)
                .setVideoEncoderFactory(new DefaultVideoEncoderFactory(egl.getEglBaseContext(), true, true))
                .setVideoDecoderFactory(new DefaultVideoDecoderFactory(egl.getEglBaseContext()))
                .createPeerConnectionFactory();
    }

    JSONObject handle(String path, JSONObject body, boolean relayed) throws Exception {
        try {
            return worker.submit(() -> {
                if (path.equals("/v1/offer")) return offer(body, relayed);
                requireSession(body);
                lastPing = SystemClock.elapsedRealtime();
                if (path.equals("/v1/ping")) return status();
                if (path.equals("/v1/disconnect")) { stopSession(); return status(); }
                if (path.equals("/v1/control")) {
                    String lens = body.optString("camera", camera);
                    boolean nextVideo = body.has("video") ? body.getBoolean("video") : video;
                    boolean nextMic = body.has("microphone") ? body.getBoolean("microphone") : microphone;
                    boolean nextTorch = body.has("torch") ? body.getBoolean("torch") : torchWanted;
                    validateLens(lens);
                    try { configure(lens, nextVideo, nextMic); }
                    catch (Exception problem) { stopSession(); throw new ApiError(400, "Input failed. Reconnect the receiver."); }
                    setTorch(nextTorch);
                    return status();
                }
                throw new ApiError(404, "Unknown endpoint.");
            }).get(25, TimeUnit.SECONDS);
        } catch (java.util.concurrent.ExecutionException failure) {
            if (failure.getCause() instanceof ApiError) throw (ApiError) failure.getCause();
            throw failure;
        }
    }

    /**
     * Starts a session. Private offers (Wi-Fi or Tailscale) use host candidates on private addresses only.
     * Relayed offers come through the sealed relay and may use Cloudflare STUN/TURN and public addresses.
     */
    private JSONObject offer(JSONObject body, boolean relayed) throws Exception {
        if (peer != null) throw new ApiError(409, "A receiver is already connected. Disconnect it first.");
        String lens = body.optString("camera", "rear");
        validateLens(lens);
        boolean requestedVideo = body.getBoolean("video"), requestedMic = body.getBoolean("microphone");
        if (!requestedVideo && !requestedMic) throw new ApiError(400, "Enable camera or microphone.");
        String offer = body.getString("sdp");
        if (!body.optString("type").equals("offer") || !offer.contains("m=video ") || !offer.contains("m=audio "))
            throw new ApiError(400, "An offer with audio and video transceivers is required.");
        try {
            PeerConnection.RTCConfiguration config = new PeerConnection.RTCConfiguration(
                    relayed ? iceServers(body.optJSONArray("ice_servers")) : Collections.emptyList());
            config.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
            config.continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE;
            config.disableIPv6OnWifi = false;
            config.maxIPv6Networks = 8;
            gathered = new CompletableFuture<>();
            long thisGeneration = ++generation;
            peer = factory.createPeerConnection(config, new PeerConnection.Observer() {
                public void onSignalingChange(PeerConnection.SignalingState state) { }
                public void onIceConnectionChange(PeerConnection.IceConnectionState state) { }
                public void onIceConnectionReceivingChange(boolean receiving) { }
                public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
                    if (thisGeneration == generation && state == PeerConnection.IceGatheringState.COMPLETE && gathered != null) gathered.complete(null);
                }
                public void onIceCandidate(IceCandidate candidate) { }
                public void onIceCandidatesRemoved(IceCandidate[] candidates) { }
                public void onAddStream(MediaStream stream) { }
                public void onRemoveStream(MediaStream stream) { }
                public void onDataChannel(DataChannel channel) { channel.close(); channel.dispose(); }
                public void onRenegotiationNeeded() { }
                public void onConnectionChange(PeerConnection.PeerConnectionState state) {
                    if (thisGeneration == generation) connection = state.name().toLowerCase(java.util.Locale.ROOT);
                }
            });
            if (peer == null) throw new IllegalStateException("Peer unavailable");
            peer.setAudioPlayout(false);
            peer.setAudioRecording(false);
            videoSource = factory.createVideoSource(false);
            videoTrack = factory.createVideoTrack("camera", videoSource);
            videoTrack.setEnabled(false);
            videoTrack.addSink(frame -> videoFrames++);
            audioSource = factory.createAudioSource(new MediaConstraints());
            audioTrack = factory.createAudioTrack("microphone", audioSource);
            audioTrack.setEnabled(false);
            videoSender = peer.addTrack(videoTrack, Collections.singletonList("android-sender"));
            peer.addTrack(audioTrack, Collections.singletonList("android-sender"));
            session = UUID.randomUUID().toString(); sessionStarted = SystemClock.elapsedRealtime();
            videoFrames = 0; audioSamples = 0; lastPing = SystemClock.elapsedRealtime(); disconnectedAt = 0;
            connection = "connecting"; error = "";
            SdpResult remote = new SdpResult();
            peer.setRemoteDescription(remote, new SessionDescription(SessionDescription.Type.OFFER, relayed ? offer : privateCandidates(offer)));
            remote.done.get(6, TimeUnit.SECONDS);
            configure(lens, requestedVideo, requestedMic);
            SdpResult answer = new SdpResult();
            peer.createAnswer(answer, new MediaConstraints());
            SessionDescription description = answer.created.get(6, TimeUnit.SECONDS);
            SdpResult local = new SdpResult();
            peer.setLocalDescription(local, description);
            local.done.get(6, TimeUnit.SECONDS);
            tuneVideo();
            if (relayed) {
                // TURN allocations can be slow on cellular; answer with the candidates gathered so far.
                try { gathered.get(8, TimeUnit.SECONDS); } catch (TimeoutException partial) { }
            } else gathered.get(6, TimeUnit.SECONDS);
            String answerSdp = peer.getLocalDescription().description;
            return new JSONObject().put("type", "answer").put("sdp", relayed ? answerSdp : privateCandidates(answerSdp))
                    .put("session", session).put("heartbeat_seconds", 10).put("lease_seconds", 45);
        } catch (Exception problem) {
            stopSession(); error = "Stream could not start. Check permissions and reconnect.";
            throw new ApiError(400, error);
        }
    }

    /**
     * WebRTC's default trades resolution away first when the link or encoder is strained, which left the viewer
     * at 480 × 270 from a 1280 × 720 capture. Keep resolution and let frame rate give way instead, and start the
     * bitrate high enough for a sharp picture.
     */
    private void tuneVideo() {
        if (videoSender == null) return;
        RtpParameters parameters = videoSender.getParameters();
        if (parameters == null || parameters.encodings.isEmpty()) return;
        parameters.degradationPreference = RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION;
        for (RtpParameters.Encoding encoding : parameters.encodings) {
            encoding.minBitrateBps = 600_000;
            encoding.maxBitrateBps = 2_500_000;
            encoding.maxFramerate = 15;
        }
        videoSender.setParameters(parameters);
    }

    /** Reads what the encoder is actually sending, for status and tuning. Media is not inspected. */
    private void refreshSendStats() {
        if (peer == null) { sendWidth = sendHeight = sendFps = targetKbps = 0; qualityLimit = ""; return; }
        peer.getStats(report -> {
            for (RTCStats stats : report.getStatsMap().values()) {
                if (!"outbound-rtp".equals(stats.getType()) || !"video".equals(stats.getMembers().get("kind"))) continue;
                java.util.Map<String, Object> values = stats.getMembers();
                sendWidth = number(values.get("frameWidth")); sendHeight = number(values.get("frameHeight"));
                sendFps = number(values.get("framesPerSecond")); targetKbps = number(values.get("targetBitrate")) / 1000;
                Object limit = values.get("qualityLimitationReason"); qualityLimit = limit == null ? "" : limit.toString();
            }
        });
    }

    private static int number(Object value) { return value instanceof Number ? (int) Math.round(((Number) value).doubleValue()) : 0; }

    /** Accepts only Cloudflare STUN/TURN entries from a sealed relayed offer. */
    static List<PeerConnection.IceServer> iceServers(JSONArray list) throws Exception {
        List<PeerConnection.IceServer> result = new ArrayList<>();
        if (list == null) return result;
        for (int i = 0; i < Math.min(list.length(), 4); i++) {
            JSONObject entry = list.getJSONObject(i);
            JSONArray urls = entry.optJSONArray("urls");
            if (urls == null) continue;
            List<String> allowed = new ArrayList<>();
            for (int j = 0; j < Math.min(urls.length(), 8); j++)
                if (SenderPolicy.isRelayIceUrl(urls.optString(j))) allowed.add(urls.getString(j));
            if (allowed.isEmpty()) continue;
            PeerConnection.IceServer.Builder server = PeerConnection.IceServer.builder(allowed);
            if (entry.has("username")) server.setUsername(entry.getString("username")).setPassword(entry.optString("credential"));
            result.add(server.createIceServer());
        }
        return result;
    }

    static String privateCandidates(String sdp) {
        StringBuilder result = new StringBuilder();
        for (String line : sdp.split("\r?\n")) {
            if (line.startsWith("a=candidate:")) {
                String[] fields = line.split(" ");
                if (fields.length < 6 || !SenderPolicy.isPrivateAddress(fields[4])) continue;
            }
            result.append(line).append("\r\n");
        }
        return result.toString();
    }

    private void configure(String lens, boolean nextVideo, boolean nextMic) throws Exception {
        if (video && (!nextVideo || !camera.equals(lens))) stopCamera();
        camera = lens;
        if (nextVideo && capturer == null) {
            Camera2Enumerator cameras = new Camera2Enumerator(context);
            String selected = null;
            for (String name : cameras.getDeviceNames()) {
                if (lens.equals("rear") ? cameras.isBackFacing(name) : cameras.isFrontFacing(name)) { selected = name; break; }
            }
            if (selected == null) throw new IllegalStateException("Camera unavailable");
            capturer = cameras.createCapturer(selected, new CameraVideoCapturer.CameraEventsHandler() {
                public void onCameraError(String description) { error = "Camera unavailable. Reconnect the receiver."; }
                public void onCameraDisconnected() { error = "Camera disconnected. Reconnect the receiver."; }
                public void onCameraFreezed(String description) { error = "Camera stopped responding. Reconnect the receiver."; }
                public void onCameraOpening(String name) { }
                public void onFirstFrameAvailable() { worker.execute(() -> setTorch(torchWanted)); }
                public void onCameraClosed() { }
            });
            texture = SurfaceTextureHelper.create("sender-camera", egl.getEglBaseContext());
            capturer.initialize(texture, context, videoSource.getCapturerObserver());
            capturer.startCapture(1280, 720, 15);
        }
        video = nextVideo; videoTrack.setEnabled(nextVideo);
        audioTrack.setEnabled(nextMic); peer.setAudioRecording(nextMic); microphone = nextMic;
    }

    private void stopCamera() throws InterruptedException {
        if (capturer != null) { capturer.stopCapture(); capturer.dispose(); capturer = null; }
        if (texture != null) { texture.dispose(); texture = null; }
        video = false; torch = false; torchWanted = false;
    }

    /**
     * The light works only with the rear camera live; switching lens, turning video off or Stop clears it.
     * A request made while the camera is still opening is applied when its first frame arrives.
     */
    private void setTorch(boolean wanted) {
        boolean allowed = wanted && video && capturer != null && camera.equals("rear") && rearHasFlash();
        torchWanted = allowed;
        if (allowed == torch || capturer == null) return;
        if (CameraTorch.set(capturer, allowed)) torch = allowed;
        else if (!allowed) torch = false;
    }

    private boolean rearHasFlash() {
        if (rearFlash == null) rearFlash = CameraTorch.rearHasFlash(
                (android.hardware.camera2.CameraManager) context.getSystemService(Context.CAMERA_SERVICE));
        return rearFlash;
    }

    private void validateLens(String lens) throws ApiError {
        if (!lens.equals("rear") && !lens.equals("front")) throw new ApiError(400, "Choose rear or front camera.");
    }

    private void requireSession(JSONObject body) throws Exception {
        if (session.isEmpty() || !session.equals(body.optString("session"))) throw new ApiError(409, "Receiver session expired. Reconnect.");
    }

    JSONObject status() throws Exception {
        return new JSONObject().put("viewer", !session.isEmpty()).put("connection", connection)
                .put("camera", camera).put("video", video).put("microphone", microphone)
                .put("audio_input_active", audioInputActive).put("video_frames", videoFrames)
                .put("audio_samples", audioSamples).put("error", error)
                .put("session_seconds", session.isEmpty() ? 0 : (SystemClock.elapsedRealtime() - sessionStarted) / 1000)
                .put("send_width", sendWidth).put("send_height", sendHeight).put("send_fps", sendFps)
                .put("target_kbps", targetKbps).put("quality_limit", qualityLimit)
                .put("torch", torch).put("torch_available", rearHasFlash());
    }

    void tick() {
        if (closed) return;
        worker.execute(() -> {
            refreshSendStats();
            if (peer == null) return;
            long now = SystemClock.elapsedRealtime();
            if (connection.equals("disconnected")) { if (disconnectedAt == 0) disconnectedAt = now; }
            else disconnectedAt = 0;
            if (now - lastPing > 45000 || connection.equals("failed") || !error.isEmpty()
                    || (disconnectedAt > 0 && now - disconnectedAt > 8000)) {
                stopSession(); error = "Receiver disconnected. Ready for a new connection.";
            }
        });
    }

    private void stopSession() {
        generation++;
        session = ""; connection = "idle"; video = false; microphone = false;
        if (peer != null) { peer.setAudioRecording(false); peer.close(); peer.dispose(); peer = null; }
        try { stopCamera(); } catch (InterruptedException stopped) { Thread.currentThread().interrupt(); }
        videoSender = null;
        if (videoTrack != null) { videoTrack.dispose(); videoTrack = null; }
        if (videoSource != null) { videoSource.dispose(); videoSource = null; }
        if (audioTrack != null) { audioTrack.dispose(); audioTrack = null; }
        if (audioSource != null) { audioSource.dispose(); audioSource = null; }
        gathered = null;
    }

    @Override public void close() {
        closed = true;
        try { worker.submit(() -> { stopSession(); factory.dispose(); audioDevice.release(); egl.release(); }).get(8, TimeUnit.SECONDS); }
        catch (Exception stopped) { android.util.Log.e("AndroidSender", "Input shutdown did not finish in time."); }
        worker.shutdown();
    }

    private static final class SdpResult implements SdpObserver {
        final CompletableFuture<Void> done = new CompletableFuture<>();
        final CompletableFuture<SessionDescription> created = new CompletableFuture<>();
        public void onCreateSuccess(SessionDescription description) { created.complete(description); }
        public void onSetSuccess() { done.complete(null); }
        public void onCreateFailure(String description) { created.completeExceptionally(new IllegalStateException("SDP failed")); }
        public void onSetFailure(String description) { done.completeExceptionally(new IllegalStateException("SDP failed")); }
    }
}
