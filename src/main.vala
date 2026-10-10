using Singularity.Nearby;

int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "");
    var system = SystemConfig.load();
    if (!system.enabled) {
        message("nearby: disabled in %s", system.source ?? "nearby.conf");
        return 0;
    }
    var config = new UserConfig(Environment.get_variable("SINGULARITY_NEARBY_DIR") ?? UserConfig.default_dir());
    try {
        config.load();
    } catch (Error e) {
        critical("nearby: cannot load the settings: %s", e.message);
        return 1;
    }
    var loop = new MainLoop();
    Service? service = null;
    Bus.own_name(BusType.SESSION, "dev.sinty.Nearby", BusNameOwnerFlags.NONE,
        (conn) => {
            try {
                service = new Service(conn, config, system);
                conn.register_object("/dev/sinty/Nearby", service);
                conn.register_object("/dev/sinty/Nearby/Collab", service.collab);
                service.start();
            } catch (Error e) {
                critical("nearby: cannot start: %s", e.message);
                loop.quit();
            }
        },
        () => {},
        () => {
            warning("nearby: lost or could not own dev.sinty.Nearby");
            loop.quit();
        });
    Unix.signal_add(Posix.Signal.TERM, () => {
        loop.quit();
        return Source.REMOVE;
    });
    Unix.signal_add(Posix.Signal.INT, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    if (service != null) service.collab.save_now();
    return 0;
}
