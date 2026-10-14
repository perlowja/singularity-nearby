using Singularity.Nearby;

Service service;
UserConfig local_config;
UserConfig peer_config;
int released = 0;

class TlsPair {
    public TlsConnection? server = null;
    public TlsConnection? client = null;
}

void on_released(Object o) {
    released++;
}

async TlsConnection accept_side(SocketListener listener, TlsCertificate own) throws Error {
    var conn = yield listener.accept_async(null, null);
    return yield Tls.handshake(conn, true, own, null, null);
}

async TlsConnection connect_side(uint16 port, TlsCertificate own) throws Error {
    var client = new SocketClient();
    var address = new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), port);
    var conn = yield client.connect_async(address, null);
    return yield Tls.handshake(conn, false, own, null, null);
}

TlsPair make_pair() throws Error {
    var listener = new SocketListener();
    SocketAddress effective;
    listener.add_address(new InetSocketAddress(new InetAddress.loopback(SocketFamily.IPV4), 0),
        SocketType.STREAM, SocketProtocol.TCP, null, out effective);
    uint16 port = (uint16) ((InetSocketAddress) effective).port;
    var pair = new TlsPair();
    var loop = new MainLoop();
    Error? failure = null;
    int pending = 2;
    accept_side.begin(listener, Tls.own_certificate(local_config), (o, r) => {
        try {
            pair.server = accept_side.end(r);
        } catch (Error e) {
            failure = e;
        }
        if (--pending == 0) loop.quit();
    });
    connect_side.begin(port, Tls.own_certificate(peer_config), (o, r) => {
        try {
            pair.client = connect_side.end(r);
        } catch (Error e) {
            failure = e;
        }
        if (--pending == 0) loop.quit();
    });
    bool timed_out = false;
    uint guard = Timeout.add_seconds(10, () => {
        timed_out = true;
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    if (!timed_out) Source.remove(guard);
    listener.close();
    if (failure != null) throw failure;
    if (pair.server == null || pair.client == null) error("the TLS handshake did not finish");
    return pair;
}

Packet peer_identity() {
    var p = new Packet(Packet.IDENTITY);
    p.set_string("deviceId", peer_config.device_id);
    p.set_string("deviceName", "Peer");
    p.set_string("deviceType", "desktop");
    p.set_int("protocolVersion", Packet.PROTOCOL_VERSION);
    return p;
}

Link new_link(TlsPair pair) {
    var link = new Link(peer_config.device_id, pair.server, new InetAddress.loopback(SocketFamily.IPV4), peer_identity());
    link.weak_ref(on_released);
    link.start();
    return link;
}

void close_peer(TlsPair pair) {
    try {
        pair.client.close();
    } catch (Error e) {
    }
    pair.client = null;
}

void settle(int want) {
    int64 end = get_monotonic_time() + 5 * TimeSpan.SECOND;
    while (released < want && get_monotonic_time() < end) {
        if (!MainContext.default().iteration(false)) Thread.usleep(2000);
    }
}

bool device_known() {
    try {
        service.get_device(peer_config.device_id);
        return true;
    } catch (Error e) {
        return false;
    }
}

void test_closed_link_is_released() {
    if (!TlsBackend.get_default().supports_tls()) {
        Test.skip("no TLS backend");
        return;
    }
    try {
        released = 0;
        var pair = make_pair();
        var link = new_link(pair);
        service.on_link(link);
        assert(device_known());
        link.close();
        link = null;
        pair.server = null;
        close_peer(pair);
        settle(1);
        assert(released == 1);
        assert(!device_known());
    } catch (Error e) {
        error(e.message);
    }
}

void test_replaced_link_is_released() {
    if (!TlsBackend.get_default().supports_tls()) {
        Test.skip("no TLS backend");
        return;
    }
    try {
        released = 0;
        var first = make_pair();
        var second = make_pair();
        var a = new_link(first);
        service.on_link(a);
        var b = new_link(second);
        service.on_link(b);
        assert(!a.open);
        assert(b.open);
        a = null;
        first.server = null;
        close_peer(first);
        settle(1);
        assert(released == 1);
        assert(device_known());
        b.close();
        b = null;
        second.server = null;
        close_peer(second);
        settle(2);
        assert(released == 2);
        assert(!device_known());
    } catch (Error e) {
        error(e.message);
    }
}

int main(string[] args) {
    Test.init(ref args);
    try {
        string dir = DirUtils.make_tmp("nearby-link-XXXXXX");
        Environment.set_variable("SINGULARITY_NEARBY_HISTORY", Path.build_filename(dir, "history.json"), true);
        local_config = new UserConfig(Path.build_filename(dir, "local"));
        local_config.load();
        peer_config = new UserConfig(Path.build_filename(dir, "peer"));
        peer_config.load();
        service = new Service(Bus.get_sync(BusType.SESSION), local_config, new SystemConfig());
    } catch (Error e) {
        error(e.message);
    }
    Test.add_func("/link/closed-link-is-released", test_closed_link_is_released);
    Test.add_func("/link/replaced-link-is-released", test_replaced_link_is_released);
    return Test.run();
}
