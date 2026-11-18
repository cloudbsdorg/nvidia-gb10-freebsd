/*
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * nv-gb10-stubs.c - fail-closed stubs for the 67 symbols that NVIDIA's
 * open RM core (open-gpu-kernel-modules 580.178.04, src/nvidia, MIT;
 * built by scripts/build-rmcore.sh) needs but the FreeBSD OS layer does
 * not provide: the 63 libspdm_* crypto hooks listed in the symbols
 * nv-kernel.o leaves undefined (scripts/build-stubs.sh prints the
 * count), declared in the core's own libspdm 3.5.0 cryptlib headers
 * and in NVIDIA's
 * nvspdm_cryptlib_extensions.h, plus the four nv_tegra_* DCE hooks
 * declared in arch/nvalloc/unix/include/nv.h. On Linux these come from
 * the Linux glue, which this port does not read or use.
 *
 * FAIL CLOSED BY DESIGN. Every crypto hook reports failure - false,
 * NULL, or the header's documented error value - so SPDM sessions,
 * Confidential Computing and SPDM attestation can never be enabled on
 * this port, and every Tegra DCE hook reports "not supported". No stub
 * ever writes through an output pointer. This is a deliberate,
 * documented limitation of the GB10 FreeBSD port.
 *
 * The includes below are the core's own (the forms and order its os.c
 * and ccsl.c use - internal/libspdm_common_lib.h, the first libspdm
 * include of the core's libspdm_includes.h, must precede cryptlib.h to
 * supply the libspdm base types); scripts/build-stubs.sh compiles this
 * file with the core's own flags plus -Werror, so any drift between a
 * stub and its real prototype is a hard compile error.
 * os/dce_rm_client_ipc.h is included for DCE_CLIENT_RM_IPC_TYPE_MAX,
 * the out-of-range sentinel nv_tegra_get_rm_interface_type reports
 * (0 would claim a valid type).
 */

#include <nv.h>
#include "os/dce_rm_client_ipc.h"
#include "internal/libspdm_common_lib.h"
#include <hal/library/cryptlib.h>
#include <nvspdm_cryptlib_extensions.h>

/* ---- cryptlib_aead.h ---- */

/* #lizard forgives -- signature is fixed by the libspdm header the open core is built against */
bool libspdm_aead_aes_gcm_encrypt(const uint8_t *key, size_t key_size,
                                  const uint8_t *iv, size_t iv_size,
                                  const uint8_t *a_data, size_t a_data_size,
                                  const uint8_t *data_in, size_t data_in_size,
                                  uint8_t *tag_out, size_t tag_size,
                                  uint8_t *data_out, size_t *data_out_size)
{
	return false;
}

/* #lizard forgives -- signature is fixed by the libspdm header the open core is built against */
bool libspdm_aead_aes_gcm_decrypt(const uint8_t *key, size_t key_size,
                                  const uint8_t *iv, size_t iv_size,
                                  const uint8_t *a_data, size_t a_data_size,
                                  const uint8_t *data_in, size_t data_in_size,
                                  const uint8_t *tag, size_t tag_size,
                                  uint8_t *data_out, size_t *data_out_size)
{
	return false;
}

/* ---- cryptlib_cert.h ---- */

bool libspdm_asn1_get_tag(uint8_t **ptr, const uint8_t *end, size_t *length, uint32_t tag)
{
	return false;
}

bool libspdm_x509_get_subject_name(const uint8_t *cert, size_t cert_size,
                                   uint8_t *cert_subject,
                                   size_t *subject_size)
{
	return false;
}

bool libspdm_x509_get_version(const uint8_t *cert, size_t cert_size, size_t *version)
{
	return false;
}

bool libspdm_x509_get_serial_number(const uint8_t *cert, size_t cert_size,
                                    uint8_t *serial_number,
                                    size_t *serial_number_size)
{
	return false;
}

bool libspdm_x509_get_signature_algorithm(const uint8_t *cert,
                                          size_t cert_size, uint8_t *oid,
                                          size_t *oid_size)
{
	return false;
}

bool libspdm_x509_get_issuer_name(const uint8_t *cert, size_t cert_size,
                                  uint8_t *cert_issuer,
                                  size_t *issuer_size)
{
	return false;
}

bool libspdm_x509_get_extension_data(const uint8_t *cert, size_t cert_size,
                                     const uint8_t *oid, size_t oid_size,
                                     uint8_t *extension_data,
                                     size_t *extension_data_size)
{
	return false;
}

bool libspdm_x509_get_validity(const uint8_t *cert, size_t cert_size,
                               uint8_t *from, size_t *from_size, uint8_t *to,
                               size_t *to_size)
{
	return false;
}

bool libspdm_x509_set_date_time(const char *date_time_str, void *date_time,
                                size_t *date_time_size)
{
	return false;
}

/*
 * cryptlib_cert.h: "If date_time1 is NULL, then return -2." and "If
 * date_time2 is NULL, then return -2." -- -2 is the header's error
 * sentinel (the only valid results are -1, 0 and 1), so every
 * comparison made through this port fails closed.
 */

int32_t libspdm_x509_compare_date_time(const void *date_time1, const void *date_time2)
{
	return -2;
}

bool libspdm_x509_get_key_usage(const uint8_t *cert, size_t cert_size, size_t *usage)
{
	return false;
}

bool libspdm_x509_get_extended_key_usage(const uint8_t *cert,
                                         size_t cert_size, uint8_t *usage,
                                         size_t *usage_size)
{
	return false;
}

bool libspdm_x509_get_extended_basic_constraints(const uint8_t *cert,
                                                 size_t cert_size,
                                                 uint8_t *basic_constraints,
                                                 size_t *basic_constraints_size)
{
	return false;
}

bool libspdm_x509_verify_cert(const uint8_t *cert, size_t cert_size,
                              const uint8_t *ca_cert, size_t ca_cert_size)
{
	return false;
}

bool libspdm_x509_verify_cert_chain(const uint8_t *root_cert, size_t root_cert_length,
                                    const uint8_t *cert_chain,
                                    size_t cert_chain_length)
{
	return false;
}

bool libspdm_x509_get_cert_from_cert_chain(const uint8_t *cert_chain,
                                           size_t cert_chain_length,
                                           const int32_t cert_index, const uint8_t **cert,
                                           size_t *cert_length)
{
	return false;
}

bool libspdm_rsa_get_public_key_from_x509(const uint8_t *cert, size_t cert_size,
                                          void **rsa_context)
{
	return false;
}

bool libspdm_ec_get_public_key_from_x509(const uint8_t *cert, size_t cert_size,
                                         void **ec_context)
{
	return false;
}

/* ---- cryptlib_ec.h ---- */

void *libspdm_ec_new_by_nid(size_t nid)
{
	return NULL;
}

void libspdm_ec_free(void *ec_context)
{
}

bool libspdm_ec_generate_key(void *ec_context, uint8_t *public_key, size_t *public_key_size)
{
	return false;
}

bool libspdm_ec_compute_key(void *ec_context, const uint8_t *peer_public,
                            size_t peer_public_size, uint8_t *key,
                            size_t *key_size)
{
	return false;
}

bool libspdm_ecdsa_verify(void *ec_context, size_t hash_nid,
                          const uint8_t *message_hash, size_t hash_size,
                          const uint8_t *signature, size_t sig_size)
{
	return false;
}

/* ---- cryptlib_hash.h ---- */

void *libspdm_sha256_new(void)
{
	return NULL;
}

void libspdm_sha256_free(void *sha256_context)
{
}

bool libspdm_sha256_init(void *sha256_context)
{
	return false;
}

bool libspdm_sha256_duplicate(const void *sha256_context, void *new_sha256_context)
{
	return false;
}

bool libspdm_sha256_update(void *sha256_context, const void *data, size_t data_size)
{
	return false;
}

bool libspdm_sha256_final(void *sha256_context, uint8_t *hash_value)
{
	return false;
}

bool libspdm_sha256_hash_all(const void *data, size_t data_size, uint8_t *hash_value)
{
	return false;
}

void *libspdm_sha384_new(void)
{
	return NULL;
}

void libspdm_sha384_free(void *sha384_context)
{
}

bool libspdm_sha384_init(void *sha384_context)
{
	return false;
}

bool libspdm_sha384_duplicate(const void *sha384_context, void *new_sha384_context)
{
	return false;
}

bool libspdm_sha384_update(void *sha384_context, const void *data, size_t data_size)
{
	return false;
}

bool libspdm_sha384_final(void *sha384_context, uint8_t *hash_value)
{
	return false;
}

bool libspdm_sha384_hash_all(const void *data, size_t data_size, uint8_t *hash_value)
{
	return false;
}

/* ---- cryptlib_hkdf.h ---- */

bool libspdm_hkdf_sha256_extract(const uint8_t *key, size_t key_size,
                                 const uint8_t *salt, size_t salt_size,
                                 uint8_t *prk_out, size_t prk_out_size)
{
	return false;
}

bool libspdm_hkdf_sha256_expand(const uint8_t *prk, size_t prk_size,
                                const uint8_t *info, size_t info_size,
                                uint8_t *out, size_t out_size)
{
	return false;
}

bool libspdm_hkdf_sha384_extract(const uint8_t *key, size_t key_size,
                                 const uint8_t *salt, size_t salt_size,
                                 uint8_t *prk_out, size_t prk_out_size)
{
	return false;
}

bool libspdm_hkdf_sha384_expand(const uint8_t *prk, size_t prk_size,
                                const uint8_t *info, size_t info_size,
                                uint8_t *out, size_t out_size)
{
	return false;
}

/* ---- cryptlib_mac.h ---- */

void *libspdm_hmac_sha256_new(void)
{
	return NULL;
}

void libspdm_hmac_sha256_free(void *hmac_sha256_ctx)
{
}

bool libspdm_hmac_sha256_set_key(void *hmac_sha256_ctx, const uint8_t *key, size_t key_size)
{
	return false;
}

bool libspdm_hmac_sha256_update(void *hmac_sha256_ctx, const void *data, size_t data_size)
{
	return false;
}

bool libspdm_hmac_sha256_final(void *hmac_sha256_ctx, uint8_t *hmac_value)
{
	return false;
}

bool libspdm_hmac_sha256_all(const void *data, size_t data_size,
                             const uint8_t *key, size_t key_size,
                             uint8_t *hmac_value)
{
	return false;
}

bool libspdm_hmac_sha384_all(const void *data, size_t data_size,
                             const uint8_t *key, size_t key_size,
                             uint8_t *hmac_value)
{
	return false;
}

/* ---- cryptlib_rng.h ---- */

bool libspdm_random_bytes(uint8_t *output, size_t size)
{
	return false;
}

/* ---- cryptlib_rsa.h ---- */

void *libspdm_rsa_new(void)
{
	return NULL;
}

void libspdm_rsa_free(void *rsa_context)
{
}

bool libspdm_rsa_set_key(void *rsa_context, const libspdm_rsa_key_tag_t key_tag,
                         const uint8_t *big_number, size_t bn_size)
{
	return false;
}

bool libspdm_rsa_pss_sign(void *rsa_context, size_t hash_nid,
                          const uint8_t *message_hash, size_t hash_size,
                          uint8_t *signature, size_t *sig_size)
{
	return false;
}

bool libspdm_rsa_pss_verify(void *rsa_context, size_t hash_nid,
                            const uint8_t *message_hash, size_t hash_size,
                            const uint8_t *signature, size_t sig_size)
{
	return false;
}

/* ---- nvspdm_cryptlib_extensions.h ---- */

bool libspdm_aead_gcm_prealloc(void **context)
{
	return false;
}

void libspdm_aead_free(void *context)
{
}

/* #lizard forgives -- signature is fixed by the libspdm header the open core is built against */
bool libspdm_aead_aes_gcm_encrypt_prealloc(void *context,
        const uint8_t *key, size_t key_size,
        const uint8_t *iv, size_t iv_size,
        const uint8_t *a_data, size_t a_data_size,
        const uint8_t *data_in, size_t data_in_size,
        uint8_t *tag_out, size_t tag_size,
        uint8_t *data_out, size_t *data_out_size)
{
	return false;
}

/* #lizard forgives -- signature is fixed by the libspdm header the open core is built against */
bool libspdm_aead_aes_gcm_decrypt_prealloc(void *context,
        const uint8_t *key, size_t key_size,
        const uint8_t *iv, size_t iv_size,
        const uint8_t *a_data, size_t a_data_size,
        const uint8_t *data_in, size_t data_in_size,
        const uint8_t *tag, size_t tag_size,
        uint8_t *data_out, size_t *data_out_size)
{
	return false;
}

bool libspdm_check_crypto_backend(void)
{
	return false;
}

bool libspdm_encode_base64(const uint8_t *src, uint8_t *dst, size_t srclen, size_t *p_dstlen)
{
	return false;
}

bool libspdm_decode_base64(const uint8_t *src, uint8_t *dst, size_t srclen, size_t *p_dstlen)
{
	return false;
}

/* ---- nv.h (Tegra DCE hooks; parameter names follow the os.c callers) ---- */

/*
 * nv.h declares these four without documentation. Registration always
 * fails with NV_ERR_NOT_SUPPORTED, so no DCE IPC client can ever exist
 * on this port: the callback that would consult
 * nv_tegra_get_rm_interface_type can never fire, and send/recv and
 * unregister have no client to work on. The interface-type translator
 * still fails closed - it returns DCE_CLIENT_RM_IPC_TYPE_MAX because
 * os/dce_rm_client_ipc.h defines the valid types as SYNC 0x0 and EVENT
 * 0x1 with MAX 0x2 out of range, and nv.h documents no failure value
 * (returning 0 would claim SYNC).
 */

NvU32 NV_API_CALL nv_tegra_get_rm_interface_type(NvU32 interfaceType)
{
	return DCE_CLIENT_RM_IPC_TYPE_MAX;
}

NV_STATUS NV_API_CALL nv_tegra_dce_register_ipc_client(NvU32 interfaceType,
    void *usrCtx, nvTegraDceClientIpcCallback callback, NvU32 *clientId)
{
	return NV_ERR_NOT_SUPPORTED;
}

NV_STATUS NV_API_CALL nv_tegra_dce_client_ipc_send_recv(NvU32 clientId,
    void *msg, NvU32 msgLength)
{
	return NV_ERR_NOT_SUPPORTED;
}

NV_STATUS NV_API_CALL nv_tegra_dce_unregister_ipc_client(NvU32 clientId)
{
	return NV_ERR_NOT_SUPPORTED;
}
