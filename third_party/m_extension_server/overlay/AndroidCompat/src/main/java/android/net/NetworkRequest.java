package android.net;

public class NetworkRequest {
    public NetworkRequest() {}

    public static class Builder {
        public Builder() {}

        public Builder addTransportType(int transportType) {
            return this;
        }

        public Builder removeTransportType(int transportType) {
            return this;
        }

        public Builder addCapability(int capability) {
            return this;
        }

        public Builder removeCapability(int capability) {
            return this;
        }

        public NetworkRequest build() {
            return new NetworkRequest();
        }
    }
}