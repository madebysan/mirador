package com.san.androidsender;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.junit.Test;
import static org.junit.Assert.*;

public class HttpRequestTest {
    private HttpRequest read(String value) throws IOException {
        return HttpRequest.read(new ByteArrayInputStream(value.getBytes(StandardCharsets.UTF_8)));
    }
    @Test public void parsesBoundedJsonRequest() throws Exception {
        HttpRequest request = read("POST /v1/control HTTP/1.1\r\nAuthorization: Bearer example\r\nContent-Length: 2\r\n\r\n{}");
        assertEquals("POST", request.method);
        assertEquals("/v1/control", request.path);
        assertEquals("Bearer example", request.headers.get("authorization"));
        assertEquals("{}", request.body);
    }
    @Test public void rejectsAmbiguousOrUnboundedBodies() {
        for (String request : new String[]{
                "POST /v1/offer HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}x",
                "POST /v1/offer HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
                "POST /v1/offer HTTP/1.1\r\nContent-Length: 131073\r\n\r\n",
                "POST /v1/offer HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
                "POST /v1/offer HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}",
                "GET /v1/status HTTP/1.1\r\nX: " + "x".repeat(8192) + "\r\n\r\n"}) {
            assertThrows(IOException.class, () -> read(request));
        }
    }
}
