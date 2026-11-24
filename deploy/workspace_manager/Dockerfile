# The workspace manager: the one container allowed to talk to the daemon.
#
# It is a plain Python HTTP server plus the Docker CLI. Nothing else is
# installed on purpose — no shell helpers, no package managers, no build tooling
# — so the only thing it can do is what manager.py explicitly asks the daemon to
# do.
FROM python:3.12-slim

# The CLI is copied from Docker's own official image; DOCKER_CONFIG points it at
# a writable directory because the container's root filesystem is read-only.
COPY --from=docker:24-cli /usr/local/bin/docker /usr/local/bin/docker

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DOCKER_CONFIG=/tmp/.docker

WORKDIR /manager
COPY workspace_manager/manager.py workspace_manager/egress_proxy.py /manager/

EXPOSE 8080
CMD ["python3", "-u", "/manager/manager.py"]
