function FindProxyForURL(url, host) {
    var myProxy = "PROXY 10.0.0.123:7890; DIRECT";

    if (isPlainHostName(host) ||
        shExpMatch(host, "*.local") ||
        isInNet(host, "10.0.0.0", "255.0.0.0") ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||
        isInNet(host, "100.64.0.0", "255.192.0.0")) {
        return "DIRECT";
    }

    return myProxy;
}
