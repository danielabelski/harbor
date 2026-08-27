#!/usr/bin/bash
# Runs from paperless-ngx's /custom-cont-init.d hook after migrations.
# PAPERLESS_ADMIN_PASSWORD is only applied by upstream when the superuser is
# first created; this keeps the existing user in sync so that
# `harbor config set paperless.admin_password` stays the truth on later boots.
log_prefix="[harbor-sync-admin-password]"

if [[ -z "${PAPERLESS_ADMIN_USER}" || -z "${PAPERLESS_ADMIN_PASSWORD}" ]]; then
	echo "${log_prefix} admin user/password not set, nothing to sync"
	exit 0
fi

cd "${PAPERLESS_SRC_DIR}" || exit 0

read -r -d '' sync_py <<'PY'
import os
from django.contrib.auth.models import User
name = os.environ["PAPERLESS_ADMIN_USER"]
password = os.environ["PAPERLESS_ADMIN_PASSWORD"]
user = User.objects.filter(username=name).first()
if user is None:
    print(f"user '{name}' does not exist yet, upstream will create it")
elif user.check_password(password):
    print(f"password for '{name}' already matches HARBOR_PAPERLESS_ADMIN_PASSWORD")
else:
    user.set_password(password)
    user.save()
    print(f"password for '{name}' updated from HARBOR_PAPERLESS_ADMIN_PASSWORD")
PY

if [[ -n "${USER_IS_NON_ROOT}" ]]; then
	python3 manage.py shell -c "${sync_py}" | sed "s/^/${log_prefix} /"
else
	s6-setuidgid paperless python3 manage.py shell -c "${sync_py}" | sed "s/^/${log_prefix} /"
fi
