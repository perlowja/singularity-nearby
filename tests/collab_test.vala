using Singularity.Nearby;

Service service;

void answer(string person, string session, bool accepted) {
    var m = new Json.Object();
    m.set_string_member("t", "answer");
    m.set_string_member("session", session);
    m.set_boolean_member("accept", accepted);
    service.collab.lan.received(person, m);
}

void assert_people(string session, int count) {
    try {
        foreach (var s in service.collab.list_sessions()) {
            if (s["id"].get_string() != session) continue;
            assert(s["people-ids"].dup_strv().length == count);
            return;
        }
        assert_not_reached();
    } catch (Error e) {
        error(e.message);
    }
}

void test_invitation_replies() {
    try {
        string session = service.collab.share("", "Note", "Private", "snapshot", "edit", (BusName) ":1.0");
        answer("other", session, true);
        assert_people(session, 0);
        service.collab.invite(session, "lan:peer");
        answer("other", session, true);
        assert_people(session, 0);
        answer("peer", session, true);
        assert_people(session, 1);
        service.collab.remove_person(session, "lan:peer");
        answer("peer", session, true);
        assert_people(session, 0);
        service.collab.invite(session, "lan:peer");
        answer("peer", session, false);
        answer("peer", session, true);
        assert_people(session, 0);
    } catch (Error e) {
        error(e.message);
    }
}

void test_pending_roundtrip() {
    var s = new CollabSession();
    s.id = "session";
    s.kind = "Note";
    s.title = "Private";
    s.role = "edit";
    s.host = "";
    s.host_name = "Host";
    s.pending.add("lan:peer");
    var restored = CollabSession.from_json(s.to_json());
    assert(restored.pending.size == 1);
    assert(restored.pending[0] == "lan:peer");
}

int main(string[] args) {
    Test.init(ref args);
    try {
        string dir = DirUtils.make_tmp("nearby-collab-XXXXXX");
        Environment.set_variable("SINGULARITY_NEARBY_HISTORY", Path.build_filename(dir, "history.json"), true);
        var config = new UserConfig(dir);
        config.load();
        service = new Service(Bus.get_sync(BusType.SESSION), config, new SystemConfig());
    } catch (Error e) {
        error(e.message);
    }
    Test.add_func("/collab/invitation-replies", test_invitation_replies);
    Test.add_func("/collab/pending-roundtrip", test_pending_roundtrip);
    return Test.run();
}
