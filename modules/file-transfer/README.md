# File Transfer

Secure file transfer over SFTP using OpenSSH — same protocol as the build-your-infra
module, running as a containerized service.

## Implementation

| Environment | Technology | Doc |
|---|---|---|
| dev | atmoz/sftp — SSH key auth, port 2222 | [docker/file-transfer-docker.md](docker/file-transfer-docker.md) |
| prod | atmoz/sftp — SSH key auth, persisted host keys, named volume | [docker/file-transfer-docker.md](docker/file-transfer-docker.md) |

**Infrastructure & AWS native equivalent:** [`modules/file-transfer`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/file-transfer)