# File Transfer

Secure file transfer over SFTP using OpenSSH — same protocol as the build-your-infra
module, running as a containerized service.

## Implementation

| Environment | Technology | Doc |
|---|---|---|
| dev | atmoz/sftp — SSH key auth, port 2222 | [file-transfer.md](file-transfer.md) |
| prod | atmoz/sftp — SSH key auth, persisted host keys, named volume | [file-transfer.md](file-transfer.md) |

**Infrastructure & AWS native equivalent:** [`modules/file-transfer`](https://github.com/Bios-Mod/build-your-infra/tree/main/modules/file-transfer)