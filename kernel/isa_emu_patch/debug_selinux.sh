#!/bin/sh
# Debug-only: boot param gbos_permissive keeps SELinux permissive (ignores setenforce 1). Idempotent.
set -e
F=/build/src/security/selinux/selinuxfs.c
grep -q gbos_permissive $F && exit 0
sed -i '/^static ssize_t sel_write_enforce(struct file \*file, const char __user \*buf,$/i \
static bool gbos_permissive;\
static int __init gbos_permissive_setup(char *s) { gbos_permissive = true; return 1; }\
__setup("gbos_permissive", gbos_permissive_setup);\
' $F
sed -i 's/^\tnew_value = !!scan_value;$/\tnew_value = !!scan_value;\n\tif (gbos_permissive \&\& new_value) {\n\t\tpr_warn_once("SELinux: gbos_permissive: ignoring setenforce 1\\n");\n\t\tnew_value = 0;\n\t}/' $F
grep -n -A4 'new_value = !!scan_value' $F; grep -n gbos_permissive_setup $F
