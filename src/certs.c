#include "certs.h"

#include <gnutls/gnutls.h>
#include <gnutls/x509.h>
#include <gnutls/abstract.h>
#include <gnutls/crypto.h>
#include <string.h>
#include <time.h>

static gboolean
fail (GError **error, const char *what, int ret)
{
  g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s: %s", what, gnutls_strerror (ret));
  return FALSE;
}

static gchar *
datum_to_string (gnutls_datum_t *datum)
{
  gchar *text = g_strndup ((const gchar *) datum->data, datum->size);
  gnutls_free (datum->data);
  return text;
}

gboolean
nearby_certs_generate (const gchar *common_name, gchar **cert_pem, gchar **key_pem, GError **error)
{
  gnutls_x509_privkey_t key = NULL;
  gnutls_x509_crt_t crt = NULL;
  gnutls_datum_t out = { NULL, 0 };
  unsigned char serial[20];
  time_t now = time (NULL);
  int ret;
  gboolean ok = FALSE;

  *cert_pem = NULL;
  *key_pem = NULL;

  if ((ret = gnutls_x509_privkey_init (&key)) < 0) {
    fail (error, "privkey_init", ret);
    goto out;
  }
  if ((ret = gnutls_x509_privkey_generate (key, GNUTLS_PK_EC, GNUTLS_CURVE_TO_BITS (GNUTLS_ECC_CURVE_SECP256R1), 0)) < 0) {
    fail (error, "privkey_generate", ret);
    goto out;
  }
  if ((ret = gnutls_x509_crt_init (&crt)) < 0) {
    fail (error, "crt_init", ret);
    goto out;
  }
  gnutls_x509_crt_set_version (crt, 3);
  if ((ret = gnutls_rnd (GNUTLS_RND_NONCE, serial, sizeof serial)) < 0) {
    fail (error, "rnd", ret);
    goto out;
  }
  serial[0] &= 0x7f;
  if (serial[0] == 0)
    serial[0] = 1;
  gnutls_x509_crt_set_serial (crt, serial, sizeof serial);
  gnutls_x509_crt_set_activation_time (crt, now - 365 * 24 * 60 * 60);
  gnutls_x509_crt_set_expiration_time (crt, now + 10L * 365 * 24 * 60 * 60);
  gnutls_x509_crt_set_dn_by_oid (crt, GNUTLS_OID_X520_COMMON_NAME, 0, common_name, strlen (common_name));
  gnutls_x509_crt_set_dn_by_oid (crt, GNUTLS_OID_X520_ORGANIZATION_NAME, 0, "KDE", 3);
  gnutls_x509_crt_set_dn_by_oid (crt, GNUTLS_OID_X520_ORGANIZATIONAL_UNIT_NAME, 0, "KDE Connect", 11);
  gnutls_x509_crt_set_issuer_dn_by_oid (crt, GNUTLS_OID_X520_COMMON_NAME, 0, common_name, strlen (common_name));
  gnutls_x509_crt_set_issuer_dn_by_oid (crt, GNUTLS_OID_X520_ORGANIZATION_NAME, 0, "KDE", 3);
  gnutls_x509_crt_set_issuer_dn_by_oid (crt, GNUTLS_OID_X520_ORGANIZATIONAL_UNIT_NAME, 0, "KDE Connect", 11);
  if ((ret = gnutls_x509_crt_set_key (crt, key)) < 0) {
    fail (error, "crt_set_key", ret);
    goto out;
  }
  if ((ret = gnutls_x509_crt_sign2 (crt, crt, key, GNUTLS_DIG_SHA512, 0)) < 0) {
    fail (error, "crt_sign", ret);
    goto out;
  }
  if ((ret = gnutls_x509_crt_export2 (crt, GNUTLS_X509_FMT_PEM, &out)) < 0) {
    fail (error, "crt_export", ret);
    goto out;
  }
  *cert_pem = datum_to_string (&out);
  if ((ret = gnutls_x509_privkey_export2_pkcs8 (key, GNUTLS_X509_FMT_PEM, NULL, GNUTLS_PKCS_PLAIN, &out)) < 0) {
    fail (error, "privkey_export", ret);
    g_clear_pointer (cert_pem, g_free);
    goto out;
  }
  *key_pem = datum_to_string (&out);
  ok = TRUE;

out:
  if (crt)
    gnutls_x509_crt_deinit (crt);
  if (key)
    gnutls_x509_privkey_deinit (key);
  return ok;
}

static gnutls_x509_crt_t
import_pem (const gchar *pem, GError **error)
{
  gnutls_x509_crt_t crt = NULL;
  gnutls_datum_t in = { (unsigned char *) pem, (unsigned int) strlen (pem) };
  int ret;

  if ((ret = gnutls_x509_crt_init (&crt)) < 0) {
    fail (error, "crt_init", ret);
    return NULL;
  }
  if ((ret = gnutls_x509_crt_import (crt, &in, GNUTLS_X509_FMT_PEM)) < 0) {
    fail (error, "crt_import", ret);
    gnutls_x509_crt_deinit (crt);
    return NULL;
  }
  return crt;
}

GBytes *
nearby_certs_public_key_der (const gchar *cert_pem, GError **error)
{
  gnutls_x509_crt_t crt;
  gnutls_pubkey_t pub = NULL;
  gnutls_datum_t out = { NULL, 0 };
  GBytes *bytes = NULL;
  int ret;

  crt = import_pem (cert_pem, error);
  if (!crt)
    return NULL;
  if ((ret = gnutls_pubkey_init (&pub)) < 0) {
    fail (error, "pubkey_init", ret);
    goto out;
  }
  if ((ret = gnutls_pubkey_import_x509 (pub, crt, 0)) < 0) {
    fail (error, "pubkey_import", ret);
    goto out;
  }
  if ((ret = gnutls_pubkey_export2 (pub, GNUTLS_X509_FMT_DER, &out)) < 0) {
    fail (error, "pubkey_export", ret);
    goto out;
  }
  bytes = g_bytes_new (out.data, out.size);
  gnutls_free (out.data);

out:
  if (pub)
    gnutls_pubkey_deinit (pub);
  gnutls_x509_crt_deinit (crt);
  return bytes;
}

gchar *
nearby_certs_common_name (const gchar *cert_pem, GError **error)
{
  gnutls_x509_crt_t crt;
  char buf[256];
  size_t size = sizeof buf;
  int ret;

  crt = import_pem (cert_pem, error);
  if (!crt)
    return NULL;
  ret = gnutls_x509_crt_get_dn_by_oid (crt, GNUTLS_OID_X520_COMMON_NAME, 0, 0, buf, &size);
  gnutls_x509_crt_deinit (crt);
  if (ret < 0) {
    fail (error, "get_dn", ret);
    return NULL;
  }
  return g_strndup (buf, size);
}
