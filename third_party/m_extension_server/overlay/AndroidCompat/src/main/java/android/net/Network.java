package android.net;

import java.net.Socket;
import java.net.URL;
import java.net.URLConnection;
import java.io.IOException;

public class Network {
    public Network() {}

    public URLConnection openConnection(URL url) throws IOException {
        return null;
    }

    public URLConnection openConnection() throws IOException {
        return null;
    }

    public void bindSocket(Socket socket) throws IOException {}

    public long getNetworkHandle() {
        return 0;
    }

    @Override
    public int hashCode() {
        return 0;
    }

    @Override
    public boolean equals(Object obj) {
        return this == obj;
    }

    @Override
    public String toString() {
        return "Network";
    }
}