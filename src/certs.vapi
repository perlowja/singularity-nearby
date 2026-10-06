[CCode (cheader_filename = "certs.h")]
namespace NearbyCerts {
    [CCode (cname = "nearby_certs_generate")]
    public bool generate(string common_name, out string cert_pem, out string key_pem) throws GLib.Error;
    [CCode (cname = "nearby_certs_public_key_der")]
    public GLib.Bytes public_key_der(string cert_pem) throws GLib.Error;
    [CCode (cname = "nearby_certs_common_name")]
    public string common_name(string cert_pem) throws GLib.Error;
}
