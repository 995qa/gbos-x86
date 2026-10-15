// SPDX-License-Identifier: GPL-2.0
/*
 * ashmem ioctls on memfd files, for kernels built without the Rust ashmem driver (CONFIG_RUST=n).
 *
 * C port of ashmem_memfd_ioctl() in drivers/staging/android/ashmem.rs. libcutils only uses memfd
 * for ashmem regions when the kernel answers ASHMEM_GET_SIZE on a memfd; otherwise it falls back
 * to /dev/ashmem, which does not exist here, and every shared Bitmap allocation fails.
 */
#include <linux/capability.h>
#include <linux/compat.h>
#include <linux/dcache.h>
#include <linux/fs.h>
#include <linux/memfd.h>
#include <linux/minmax.h>
#include <linux/mman.h>
#include <linux/string.h>
#include <linux/uaccess.h>

#include "../drivers/staging/android/ashmem.h"

#define WRITE_SEALS_MASK (F_SEAL_WRITE | F_SEAL_FUTURE_WRITE)

static long ashmem_memfd_get_name(struct file *file, void __user *argp)
{
	struct name_snapshot snap;
	char name[ASHMEM_NAME_LEN];
	const char *s;
	size_t len;

	take_dentry_name_snapshot(&snap, file->f_path.dentry);
	s = snap.name.name;
	if (!strncmp(s, "memfd:", 6))
		s += 6;
	len = min_t(size_t, strlen(s), ASHMEM_NAME_LEN - 1);
	memcpy(name, s, len);
	name[len] = '\0';
	release_dentry_name_snapshot(&snap);

	return copy_to_user(argp, name, len + 1) ? -EFAULT : 0;
}

long ashmem_memfd_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	unsigned long ino = file_inode(file)->i_ino;
	unsigned long prot;
	long seals, ret;

#ifdef CONFIG_COMPAT
	switch (cmd) {
	case COMPAT_ASHMEM_SET_SIZE:
		cmd = ASHMEM_SET_SIZE;
		break;
	case COMPAT_ASHMEM_SET_PROT_MASK:
		cmd = ASHMEM_SET_PROT_MASK;
		break;
	case COMPAT_ASHMEM_GET_FILE_ID:
		return put_user((u32)ino, (u32 __user *)compat_ptr(arg)) ? -EFAULT : 0;
	}
#endif

	switch (cmd) {
	case ASHMEM_GET_NAME:
		return ashmem_memfd_get_name(file, (void __user *)arg);
	case ASHMEM_GET_SIZE:
		return i_size_read(file_inode(file));
	case ASHMEM_SET_PROT_MASK:
		seals = memfd_fcntl(file, F_GET_SEALS, 0);
		if (seals < 0)
			return seals;
		/* The memfd compat layer does not support unsetting these. */
		prot = arg | PROT_READ | PROT_EXEC;
		if (seals & WRITE_SEALS_MASK) {
			/* Can't add PROT bits. */
			return (prot & PROT_WRITE) ? -EINVAL : 0;
		}
		if (!(prot & PROT_WRITE)) {
			ret = memfd_fcntl(file, F_ADD_SEALS, F_SEAL_FUTURE_WRITE);
			if (ret < 0)
				return ret;
		}
		return 0;
	case ASHMEM_GET_PROT_MASK:
		seals = memfd_fcntl(file, F_GET_SEALS, 0);
		if (seals < 0)
			return seals;
		return PROT_READ | PROT_EXEC | ((seals & WRITE_SEALS_MASK) ? 0 : PROT_WRITE);
	case ASHMEM_GET_FILE_ID:
		return put_user(ino, (unsigned long __user *)arg) ? -EFAULT : 0;
	/* Just ignore unpin requests. */
	case ASHMEM_PIN:
		return ASHMEM_NOT_PURGED;
	case ASHMEM_UNPIN:
		return 0;
	case ASHMEM_GET_PIN_STATUS:
		return ASHMEM_IS_PINNED;
	case ASHMEM_PURGE_ALL_CACHES:
		return capable(CAP_SYS_ADMIN) ? 0 : -EPERM;
	/* libcutils sets name and size where it creates the fd, knowing it is a memfd. */
	case ASHMEM_SET_NAME:
	case ASHMEM_SET_SIZE:
		return -EINVAL;
	default:
		return -ENOTTY;
	}
}
