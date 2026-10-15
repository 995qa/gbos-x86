// SPDX-License-Identifier: Apache-2.0
/*
 * soft_gk: software android.hardware.gatekeeper.IGatekeeper/default (AIDL V1) for gbos.
 *
 * The lapis Gatekeeper is Trusty-backed and Trusty needs Google's security chip, so enroll never
 * returns. This replaces it with an HMAC-signed password handle, like AOSP's software Gatekeeper.
 *
 * Built without the NDK: no headers, the few bionic / libbinder_ndk / BoringSSL / liblog symbols
 * it uses are declared below and it links straight against the image's .so files (build.sh).
 * The wire format follows android.hardware.gatekeeper-V1-ndk.so: codes 1 deleteAllUsers,
 * 2 deleteUser, 3 enroll, 4 verify, 0xffffff getInterfaceVersion, 0xfffffe getInterfaceHash.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ---- bionic ---- */
typedef struct { void (**preinit_array)(void); void (**init_array)(void); void (**fini_array)(void);
		 size_t preinit_array_count, init_array_count, fini_array_count; } structors_array_t;
void __libc_init(void *raw_args, void (*onexit)(void), int (*main)(int, char **, char **),
		 const structors_array_t *structors) __attribute__((noreturn));
void *malloc(size_t); void free(void *);
void *memcpy(void *, const void *, size_t); int memcmp(const void *, const void *, size_t);
void arc4random_buf(void *, size_t);
struct timespec { long tv_sec, tv_nsec; };
int clock_gettime(int, struct timespec *);
#define CLOCK_BOOTTIME 7

/* ---- liblog ---- */
int __android_log_print(int prio, const char *tag, const char *fmt, ...);
#define LOGI(...) __android_log_print(4, "soft_gk", __VA_ARGS__)
#define LOGE(...) __android_log_print(6, "soft_gk", __VA_ARGS__)

/* ---- BoringSSL ---- */
typedef struct env_md_st EVP_MD;
const EVP_MD *EVP_sha256(void);
uint8_t *HMAC(const EVP_MD *, const void *key, size_t key_len, const uint8_t *data, size_t data_len,
	      uint8_t *out, unsigned int *out_len);
int CRYPTO_memcmp(const void *, const void *, size_t);

/* ---- libbinder_ndk ---- */
typedef struct AIBinder AIBinder; typedef struct AIBinder_Class AIBinder_Class;
typedef struct AParcel AParcel; typedef struct AStatus AStatus;
typedef int32_t binder_status_t; typedef uint32_t transaction_code_t;
AIBinder_Class *AIBinder_Class_define(const char *descriptor, void *(*on_create)(void *),
	void (*on_destroy)(void *),
	binder_status_t (*on_transact)(AIBinder *, transaction_code_t, const AParcel *, AParcel *));
AIBinder *AIBinder_new(const AIBinder_Class *, void *args);
void AIBinder_markVintfStability(AIBinder *);
int32_t AServiceManager_addService(AIBinder *, const char *instance);
bool ABinderProcess_setThreadPoolMaxThreadCount(uint32_t);
void ABinderProcess_joinThreadPool(void);
binder_status_t AParcel_readInt32(const AParcel *, int32_t *);
binder_status_t AParcel_readInt64(const AParcel *, int64_t *);
binder_status_t AParcel_readByteArray(const AParcel *, void *data,
	bool (*alloc)(void *data, int32_t len, int8_t **out));
binder_status_t AParcel_writeInt32(AParcel *, int32_t);
binder_status_t AParcel_writeInt64(AParcel *, int64_t);
binder_status_t AParcel_writeByteArray(AParcel *, const int8_t *, int32_t len);
binder_status_t AParcel_writeString(AParcel *, const char *, int32_t len);
int32_t AParcel_getDataPosition(const AParcel *);
binder_status_t AParcel_setDataPosition(const AParcel *, int32_t);
binder_status_t AParcel_writeStatusHeader(AParcel *, const AStatus *);
AStatus *AStatus_newOk(void); void AStatus_delete(AStatus *);
#define STATUS_OK 0
#define STATUS_UNKNOWN_TRANSACTION (-74)

/* ---- Gatekeeper ---- */
#define DESCRIPTOR "android.hardware.gatekeeper.IGatekeeper"
#define INSTANCE DESCRIPTOR "/default"
#define IFACE_HASH "d877e8a1608a00fd9068bcd7e69ea480a7ea17f0"
enum { GK_OK = 0, GK_ERROR_GENERAL_FAILURE = -1 };
enum { HW_AUTH_PASSWORD = 1 };

/* gatekeeper::password_handle_t (system/gatekeeper/include/gatekeeper/password_handle.h).
 * gatekeeperd rejects any handle that isn't exactly this size. */
struct __attribute__((packed)) password_handle {
	uint8_t version;
	uint64_t user_id;	/* secure user id */
	uint64_t flags;
	uint64_t salt;
	uint8_t signature[32];
	uint8_t hardware_backed;
};
#define HANDLE_VERSION 2

/* Fixed keys: this is a software Gatekeeper with no secure storage, and /data is tmpfs anyway. */
static const uint8_t pw_key[32] = "gbos soft gatekeeper password k";
static const uint8_t auth_key[32] = "gbos soft gatekeeper authtoken ";

struct bytes { int8_t *p; int32_t len; };	/* len -1: null */

static bool byte_alloc(void *data, int32_t len, int8_t **out)
{
	struct bytes *b = data;
	b->len = len;
	b->p = len > 0 ? malloc(len) : NULL;
	*out = b->p;
	return len <= 0 || b->p;
}

static void sign(uint64_t salt, const struct bytes *pw, uint8_t out[32])
{
	uint8_t buf[8 + 256];
	size_t n = pw->len > 0 ? (size_t)pw->len : 0;
	unsigned int len;

	if (n > 256)
		n = 256;
	memcpy(buf, &salt, 8);
	if (n)
		memcpy(buf + 8, pw->p, n);
	HMAC(EVP_sha256(), pw_key, sizeof(pw_key), buf, 8 + n, out, &len);
}

static bool handle_matches(const struct bytes *h, const struct bytes *pw)
{
	struct password_handle ph;
	uint8_t sig[32];

	if (h->len != (int32_t)sizeof(ph))
		return false;
	memcpy(&ph, h->p, sizeof(ph));
	sign(ph.salt, pw, sig);
	return CRYPTO_memcmp(sig, ph.signature, 32) == 0;
}

/* Parcelable framing: a non-null marker, then a size-prefixed body. */
static int32_t begin_parcelable(AParcel *out)
{
	int32_t start;

	AParcel_writeInt32(out, 1);
	start = AParcel_getDataPosition(out);
	AParcel_writeInt32(out, 0);
	return start;
}

static void end_parcelable(AParcel *out, int32_t start)
{
	int32_t end = AParcel_getDataPosition(out);

	AParcel_setDataPosition(out, start);
	AParcel_writeInt32(out, end - start);
	AParcel_setDataPosition(out, end);
}

static void write_ok_header(AParcel *out)
{
	AStatus *st = AStatus_newOk();

	AParcel_writeStatusHeader(out, st);
	AStatus_delete(st);
}

static binder_status_t do_enroll(const AParcel *in, AParcel *out)
{
	int32_t uid;
	struct bytes cur_h = {0}, cur_pw = {0}, new_pw = {0};
	struct password_handle ph = {0};
	int32_t status = GK_OK, start;
	binder_status_t r;

	if ((r = AParcel_readInt32(in, &uid)) || (r = AParcel_readByteArray(in, &cur_h, byte_alloc)) ||
	    (r = AParcel_readByteArray(in, &cur_pw, byte_alloc)) ||
	    (r = AParcel_readByteArray(in, &new_pw, byte_alloc)))
		goto out;

	if (cur_h.len > 0) {
		/* Changing an existing credential: keep the secure user id if the old password checks out. */
		if (!handle_matches(&cur_h, &cur_pw)) {
			status = GK_ERROR_GENERAL_FAILURE;
		} else {
			memcpy(&ph, cur_h.p, sizeof(ph));
		}
	} else {
		arc4random_buf(&ph.user_id, sizeof(ph.user_id));
	}
	if (status == GK_OK) {
		ph.version = HANDLE_VERSION;
		ph.flags = 0;
		ph.hardware_backed = 1;
		arc4random_buf(&ph.salt, sizeof(ph.salt));
		sign(ph.salt, &new_pw, ph.signature);
	}
	LOGI("enroll uid=%d replace=%d -> %d", uid, cur_h.len > 0, status);

	write_ok_header(out);
	start = begin_parcelable(out);	/* GatekeeperEnrollResponse */
	AParcel_writeInt32(out, status);
	AParcel_writeInt32(out, 0);	/* timeoutMs */
	AParcel_writeInt64(out, status == GK_OK ? (int64_t)ph.user_id : 0);
	if (status == GK_OK)
		AParcel_writeByteArray(out, (const int8_t *)&ph, sizeof(ph));
	else
		AParcel_writeByteArray(out, NULL, -1);
	end_parcelable(out, start);
	r = STATUS_OK;
out:
	free(cur_h.p); free(cur_pw.p); free(new_pw.p);
	return r;
}

static uint64_t htonq(uint64_t v) { return __builtin_bswap64(v); }

static binder_status_t do_verify(const AParcel *in, AParcel *out)
{
	int32_t uid, status, start, tstart;
	int64_t challenge, now_ms = 0;
	struct bytes h = {0}, pw = {0};
	struct password_handle ph = {0};
	binder_status_t r;

	if ((r = AParcel_readInt32(in, &uid)) || (r = AParcel_readInt64(in, &challenge)) ||
	    (r = AParcel_readByteArray(in, &h, byte_alloc)) || (r = AParcel_readByteArray(in, &pw, byte_alloc)))
		goto out;

	status = handle_matches(&h, &pw) ? GK_OK : GK_ERROR_GENERAL_FAILURE;
	if (status == GK_OK) {
		struct timespec ts;

		memcpy(&ph, h.p, sizeof(ph));
		clock_gettime(CLOCK_BOOTTIME, &ts);
		now_ms = ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
	}
	LOGI("verify uid=%d -> %d", uid, status);

	write_ok_header(out);
	start = begin_parcelable(out);	/* GatekeeperVerifyResponse */
	AParcel_writeInt32(out, status);
	AParcel_writeInt32(out, 0);	/* timeoutMs */
	tstart = begin_parcelable(out);	/* HardwareAuthToken */
	AParcel_writeInt64(out, status == GK_OK ? challenge : 0);
	AParcel_writeInt64(out, (int64_t)ph.user_id);
	AParcel_writeInt64(out, 0);	/* authenticatorId */
	AParcel_writeInt32(out, status == GK_OK ? HW_AUTH_PASSWORD : 0);
	{
		int32_t s = begin_parcelable(out);	/* Timestamp */

		AParcel_writeInt64(out, now_ms);
		end_parcelable(out, s);
	}
	if (status == GK_OK) {
		/* KeyMint layout: 0 || challenge || user_id || authenticator_id || htonl(type) || htonq(ts).
		 * Signed with our own key: the software KeyMint's shared HMAC key isn't known here. */
		uint8_t buf[1 + 8 + 8 + 8 + 4 + 8], mac[32];
		uint64_t zero = 0, ts_be = htonq((uint64_t)now_ms);
		uint32_t type_be = __builtin_bswap32(HW_AUTH_PASSWORD);
		unsigned int len;

		buf[0] = 0;
		memcpy(buf + 1, &challenge, 8);
		memcpy(buf + 9, &ph.user_id, 8);
		memcpy(buf + 17, &zero, 8);
		memcpy(buf + 25, &type_be, 4);
		memcpy(buf + 29, &ts_be, 8);
		HMAC(EVP_sha256(), auth_key, sizeof(auth_key), buf, sizeof(buf), mac, &len);
		AParcel_writeByteArray(out, (const int8_t *)mac, 32);
	} else {
		AParcel_writeByteArray(out, NULL, 0);
	}
	end_parcelable(out, tstart);
	end_parcelable(out, start);
	r = STATUS_OK;
out:
	free(h.p); free(pw.p);
	return r;
}

static void *on_create(void *args) { return args; }
static void on_destroy(void *data) { (void)data; }

static binder_status_t on_transact(AIBinder *b, transaction_code_t code, const AParcel *in, AParcel *out)
{
	int32_t uid;

	(void)b;
	switch (code) {
	case 1:		/* deleteAllUsers: handles live in LockSettings, nothing stored here */
		write_ok_header(out);
		return STATUS_OK;
	case 2:		/* deleteUser */
		AParcel_readInt32(in, &uid);
		write_ok_header(out);
		return STATUS_OK;
	case 3:
		return do_enroll(in, out);
	case 4:
		return do_verify(in, out);
	case 0xffffff:	/* getInterfaceVersion */
		write_ok_header(out);
		return AParcel_writeInt32(out, 1);
	case 0xfffffe:	/* getInterfaceHash */
		write_ok_header(out);
		return AParcel_writeString(out, IFACE_HASH, sizeof(IFACE_HASH) - 1);
	default:
		return STATUS_UNKNOWN_TRANSACTION;
	}
}

int main(int argc, char **argv, char **envp)
{
	AIBinder_Class *cls;
	AIBinder *binder;
	int32_t ex;

	(void)argc; (void)argv; (void)envp;
	ABinderProcess_setThreadPoolMaxThreadCount(0);
	cls = AIBinder_Class_define(DESCRIPTOR, on_create, on_destroy, on_transact);
	binder = AIBinder_new(cls, NULL);
	AIBinder_markVintfStability(binder);
	ex = AServiceManager_addService(binder, INSTANCE);
	if (ex != 0) {
		LOGE("addService(%s) failed: %d", INSTANCE, ex);
		return 1;
	}
	LOGI("registered %s", INSTANCE);
	ABinderProcess_joinThreadPool();
	return 0;
}

static const structors_array_t structors;

int start_main(void *raw_args) __asm__("gk_start_main");
__attribute__((used)) int start_main(void *raw_args)
{
	__libc_init(raw_args, NULL, main, &structors);
}

__asm__(".text\n.globl _start\n.type _start,@function\n_start:\n"
	"  xorl %ebp, %ebp\n  movq %rsp, %rdi\n  andq $-16, %rsp\n  call gk_start_main\n  hlt\n");
