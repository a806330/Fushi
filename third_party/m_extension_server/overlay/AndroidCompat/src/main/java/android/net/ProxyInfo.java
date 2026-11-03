package android.net;

public class ProxyInfo {
    public ProxyInfo() {}

    public ProxyInfo(String host, int port, String exclList) {}

    public String getHost() {
        return null;
    }

    public int getPort() {
        return 0;
    }

    public String getExclusionListAsString() {
        return null;
    }

    public String[] getExclusionList() {
        return new String[0];
    }
}