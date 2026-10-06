[CCode (cheader_filename = "netif.h")]
namespace NearbyNetif {
    [CCode (cname = "nearby_netif_list", array_length = false, array_null_terminated = true)]
    public string[] list();
}
