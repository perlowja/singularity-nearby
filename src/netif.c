#include "netif.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>

gchar **
nearby_netif_list (void)
{
  GPtrArray *list = g_ptr_array_new ();
  struct ifaddrs *addrs = NULL;
  struct ifaddrs *it;

  if (getifaddrs (&addrs) != 0) {
    g_ptr_array_add (list, NULL);
    return (gchar **) g_ptr_array_free (list, FALSE);
  }
  for (it = addrs; it != NULL; it = it->ifa_next) {
    char address[INET_ADDRSTRLEN] = "";
    char broadcast[INET_ADDRSTRLEN] = "";

    if (it->ifa_addr == NULL || it->ifa_addr->sa_family != AF_INET)
      continue;
    if (!(it->ifa_flags & IFF_UP) || (it->ifa_flags & IFF_LOOPBACK))
      continue;
    inet_ntop (AF_INET, &((struct sockaddr_in *) it->ifa_addr)->sin_addr, address, sizeof address);
    if ((it->ifa_flags & IFF_BROADCAST) && it->ifa_broadaddr != NULL)
      inet_ntop (AF_INET, &((struct sockaddr_in *) it->ifa_broadaddr)->sin_addr, broadcast, sizeof broadcast);
    g_ptr_array_add (list, g_strdup_printf ("%s\t%s\t%s", it->ifa_name, address, broadcast));
  }
  freeifaddrs (addrs);
  g_ptr_array_add (list, NULL);
  return (gchar **) g_ptr_array_free (list, FALSE);
}
