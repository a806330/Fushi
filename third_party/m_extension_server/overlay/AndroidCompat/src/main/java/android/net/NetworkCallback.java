package android.net;

public class NetworkCallback {
    public NetworkCallback() {}

    public void onAvailable(Network network) {}

    public void onLost(Network network) {}

    public void onCapabilitiesChanged(Network network, NetworkCapabilities networkCapabilities) {}

    public void onLinkPropertiesChanged(Network network, LinkProperties linkProperties) {}

    public void onUnavailable() {}
}