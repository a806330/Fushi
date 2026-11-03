package android.net;

import java.net.InetAddress;
import java.util.Collections;
import java.util.List;

public class LinkProperties {
    public LinkProperties() {}

    public String getInterfaceName() {
        return null;
    }

    public List<InetAddress> getAddresses() {
        return Collections.emptyList();
    }

    public List<String> getDnsServers() {
        return Collections.emptyList();
    }
}