# Security policy

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

Report them privately through GitHub: open the **Security** tab of this repository and choose **Report a vulnerability**.
Describe what you found, how to reproduce it and what an attacker could do with it.

You will get an answer as soon as possible. Once a fix is available, the problem and your report (with credit, if you want) are published.

## Scope

Especially welcome are findings about:

- the vault format and its cryptography ([docs/FORMAT.md](docs/FORMAT.md))
- ways decrypted data could reach the disk, the clipboard, other apps or the network
- metadata that survives **Remove metadata when exporting**
- anything that contradicts the [threat model](docs/THREAT_MODEL.md)

Out of scope: attacks that need full control of the Mac while the vault is unlocked (see the threat model).
