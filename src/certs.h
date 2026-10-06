#pragma once

#include <gio/gio.h>

gboolean nearby_certs_generate (const gchar *common_name, gchar **cert_pem, gchar **key_pem, GError **error);
GBytes *nearby_certs_public_key_der (const gchar *cert_pem, GError **error);
gchar *nearby_certs_common_name (const gchar *cert_pem, GError **error);
